-------------------------------------------------------------------------------
-- RaiseAllWindows.spoon
--
-- When a configured application becomes active (e.g., via Dock click or
-- Cmd+Tab), brings all of its visible windows above other apps' windows.
-- Restores the older macOS behavior where activating an app raised every
-- one of its windows, not just the most recently focused one.
--
-- Implementation uses NSRunningApplication's activateWithOptions: with
-- NSApplicationActivateAllWindows (exposed in Hammerspoon as
-- hs.application:activate(true)). This is a single AppKit call that the
-- WindowServer applies atomically, so there is no per-window AX cascade
-- and no visible delay between window raises.
--
-- A per-window AXRaise fallback exists for the rare case where the
-- AppKit call does not pick up every window (e.g., some apps with
-- non-standard window classes).
--
-- AutoRaise compatibility: AutoRaise changes focus when the mouse hovers
-- a window, which fires hs.application.watcher.activated even though the
-- user didn't intend to bring the app forward. We can't tell the two
-- cases apart from the watcher event itself, so we look at the most
-- recent INPUT event instead:
--   * A real activation is preceded by a click that landed on this app's
--     window (or on no window — dock, menubar, desktop), or by a
--     modified keypress (Cmd+Tab, Alt+G hotkey, etc).
--   * An AutoRaise activation, or a re-activation triggered by our own
--     activate(true), is preceded only by mouse motion or by a click on
--     a different app's window — neither of which authorizes a raise.
-- The check is targeted to avoid the loop where a click on app A (e.g.
-- the Hammerspoon Console) would authorize raises of app B (e.g. Ghostty)
-- when our activate(true) re-fires the activation watcher.
--
-- A second trap: once AutoRaise has focused an app (without raising
-- siblings), a later click on one of that app's windows does NOT fire a
-- new activation event (the app didn't change frontmost-app state). The
-- click does raise the clicked window in z-order though, so the siblings
-- are left behind. To handle this we post-process every left-click: a
-- short delay after the click, if the now-frontmost window is in a
-- configured app whose windows are NOT already clustered at the top of
-- the z-order, we raise all of them.
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "RaiseAllWindows"
obj.version = "2.1"

obj.log = hs.logger.new("RaiseAll", "info")

--- RaiseAllWindows.appNames
--- Variable
--- List of application names (as returned by hs.application:name()) for
--- which the raise-all-windows behavior is applied. Set to an empty list
--- {} to apply to every activated app.
obj.appNames = {
    "Ghostty",
}

--- RaiseAllWindows.useFallback
--- Variable
--- If true, after the AppKit activate(true) call, also perform AXRaise on
--- any visible windows that are still hidden behind other apps. Useful
--- for apps where NSApplicationActivateAllWindows does not catch every
--- window. Off by default since the AppKit path is reliable for most apps.
obj.useFallback = false

--- RaiseAllWindows.requireUserInput
--- Variable
--- If true (default), only raise-all when an authorizing input happened
--- within `userInputWindow` seconds. Authorizing means either:
---   * A modified keypress (any app — Cmd+Tab is intrinsically untargeted)
---   * A click whose target was either this app's own window or no
---     window at all (dock / menubar / desktop are all attributable to
---     the user choosing some app to bring forward).
--- A click on a *different* app's window does NOT authorize, which is
--- what stops the self-sustaining raise loop when activate(true) re-fires
--- the activation watcher.
obj.requireUserInput = true

--- RaiseAllWindows.userInputWindow
--- Variable
--- How long (in seconds) an authorizing input remains valid. 250 ms is
--- longer than typical OS delay between a click/hotkey and the
--- activation event, but short enough that stale input doesn't authorize
--- later unrelated activations.
obj.userInputWindow = 0.25

--- RaiseAllWindows.raiseOnClick
--- Variable
--- If true (default), also handle clicks that don't fire an activation
--- event (e.g., clicking a window of an app that AutoRaise has already
--- focused). After such a click, if the activated app's windows aren't
--- already all on top, raise them together.
obj.raiseOnClick = true

--- RaiseAllWindows.postClickDelay
--- Variable
--- Seconds to wait after a left-click before deciding whether the
--- siblings need raising. The OS needs a moment to process the click and
--- update z-order before our `_isAppFullyOnTop` read is meaningful.
obj.postClickDelay = 0.08

--- RaiseAllWindows.raiseCooldown
--- Variable
--- Minimum seconds between two raise-alls for the same app. Acts as a
--- hard floor against feedback loops where activate(true) keeps re-firing
--- the activation watcher.
obj.raiseCooldown = 0.3

obj._watcher = nil
obj._inputTap = nil
obj._lastClickAt = 0
obj._lastClickPid = 0
obj._lastClickKind = "none"
obj._lastKeyAt = 0
obj._lastKeyKind = "none"
obj._lastRaiseAt = {}


local function inList(value, list)
    for _, v in ipairs(list) do
        if v == value then
            return true
        end
    end
    return false
end


--- RaiseAllWindows:_shouldApply(appName) -> boolean
--- Internal: returns true if the spoon should act on this app.
function obj:_shouldApply(appName)
    if not appName then
        return false
    end
    if #self.appNames == 0 then
        return true
    end
    return inList(appName, self.appNames)
end


--- RaiseAllWindows:_isAppFullyOnTop(app) -> boolean
--- Internal: returns true if every standard visible window of `app` sits
--- above every standard visible window of every other app in z-order.
--- Used to skip redundant raise-alls when the siblings are already up.
function obj:_isAppFullyOnTop(app)
    local pid = app:pid()
    local ordered = hs.window.orderedWindows()
    local seenOther = false
    for _, w in ipairs(ordered) do
        if w:isStandard() then
            local wa = w:application()
            if wa and wa:pid() == pid then
                if seenOther then
                    return false
                end
            else
                seenOther = true
            end
        end
    end
    return true
end


--- RaiseAllWindows:_windowAtPoint(point) -> hs.window | nil
--- Internal: returns the topmost standard window whose frame contains
--- `point`, or nil if the point isn't over any window (e.g., dock,
--- menubar, desktop).
function obj:_windowAtPoint(point)
    if not point then
        return nil
    end
    for _, w in ipairs(hs.window.orderedWindows()) do
        if w:isStandard() then
            local f = w:frame()
            if f
               and point.x >= f.x and point.x < f.x + f.w
               and point.y >= f.y and point.y < f.y + f.h then
                return w
            end
        end
    end
    return nil
end


--- RaiseAllWindows:_handlePostClick(app)
--- Internal: called shortly after a left-click on a window of `app` (the
--- app under the cursor at click time). If `app`'s siblings aren't
--- already on top, raise them. This covers the case where AutoRaise had
--- already focused the app, so the click doesn't fire an activation
--- event and the watcher never gets a chance.
function obj:_handlePostClick(app)
    if not app or not app:isRunning() then
        return
    end
    local name = app:name()
    if self:_isAppFullyOnTop(app) then
        self.log.df("post-click: %s already fully on top, skip", name)
        return
    end
    self.log.i(string.format("post-click raise-all for %s (siblings behind other apps)", name))
    self:_raiseAll(app)
end


--- RaiseAllWindows:_startInputTap()
--- Internal: starts the event tap that records timestamps of user-initiated
--- activation events (clicks and modifier-key presses). The callback
--- returns false so events propagate normally.
function obj:_startInputTap()
    if self._inputTap then
        return
    end
    local et = hs.eventtap.event.types
    local watched = {
        et.leftMouseDown,
        et.rightMouseDown,
        et.otherMouseDown,
        et.keyDown,
    }
    self._inputTap = hs.eventtap.new(watched, function(event)
        local kind = event:getType()
        local now = hs.timer.secondsSinceEpoch()

        if kind == et.keyDown then
            -- Plain typing shouldn't count — only modifier-bearing presses
            -- (Cmd+Tab, Hammerspoon Alt+X hotkeys, Ctrl-based switchers).
            local flags = event:getFlags()
            if not (flags.cmd or flags.alt or flags.ctrl) then
                return false
            end
            local label = "keyDown"
            if flags.cmd then label = label .. "+cmd" end
            if flags.alt then label = label .. "+alt" end
            if flags.ctrl then label = label .. "+ctrl" end
            self._lastKeyAt = now
            self._lastKeyKind = label
            return false
        end

        -- Mouse click: identify the window under the cursor at click
        -- time so later raise-decisions can be targeted to that app.
        local hitWin = self:_windowAtPoint(event:location())
        local hitApp = hitWin and hitWin:application()
        local hitName = hitApp and hitApp:name() or nil
        self._lastClickAt = now
        self._lastClickPid = hitApp and hitApp:pid() or 0
        self._lastClickKind = hitName and ("click:" .. hitName) or "click:nowindow"

        if self.raiseOnClick and kind == et.leftMouseDown
           and hitApp and self:_shouldApply(hitName) then
            hs.timer.doAfter(self.postClickDelay, function()
                self:_handlePostClick(hitApp)
            end)
        end

        return false
    end)
    self._inputTap:start()
end


--- RaiseAllWindows:_stopInputTap()
function obj:_stopInputTap()
    if self._inputTap then
        self._inputTap:stop()
        self._inputTap = nil
    end
end


--- RaiseAllWindows:_raiseAll(app)
--- Internal: raises every visible window of `app` atomically via the
--- AppKit "activate all windows" option.
function obj:_raiseAll(app)
    if not app then
        return
    end

    local pid = app:pid()
    local now = hs.timer.secondsSinceEpoch()

    if self.requireUserInput then
        local keyAgo = now - self._lastKeyAt
        local clickAgo = now - self._lastClickAt
        local recentKey = keyAgo <= self.userInputWindow
        local clickTargetsThisApp = self._lastClickPid == pid or self._lastClickPid == 0
        local recentClickAuthorizes = clickAgo <= self.userInputWindow and clickTargetsThisApp
        if not (recentKey or recentClickAuthorizes) then
            self.log.i(string.format(
                "SKIP raise for %s: no authorizing input (key %.2fs ago [%s], click %.2fs ago [%s, pid=%d vs appPid=%d])",
                app:name(), keyAgo, self._lastKeyKind, clickAgo, self._lastClickKind,
                self._lastClickPid, pid
            ))
            return
        end
    end

    local lastAt = self._lastRaiseAt[pid] or 0
    local sinceLast = now - lastAt
    if sinceLast < self.raiseCooldown then
        self.log.df("cooldown: %s raised %.2fs ago, skip", app:name(), sinceLast)
        return
    end

    -- NSRunningApplication.activateWithOptions:NSApplicationActivateAllWindows
    -- One OS call, applied atomically by the WindowServer.
    local ok = app:activate(true)
    self._lastRaiseAt[pid] = hs.timer.secondsSinceEpoch()
    self.log.i(string.format("RAISE all windows for %s (activate ok=%s)", app:name(), tostring(ok)))

    if not self.useFallback then
        return
    end

    -- Fallback AX path for apps the AppKit call doesn't fully cover.
    local focused = app:focusedWindow()
    local focusedId = focused and focused:id() or nil
    for _, win in ipairs(app:visibleWindows()) do
        if win:isStandard() and win:id() ~= focusedId then
            win:raise()
        end
    end
    if focused and focused:isStandard() then
        focused:raise()
    end
end


--- RaiseAllWindows:start()
--- Method
--- Starts watching for application activation events.
function obj:start()
    self:stop()

    if self.requireUserInput or self.raiseOnClick then
        self:_startInputTap()
    end

    self._watcher = hs.application.watcher.new(function(appName, eventType, app)
        if eventType ~= hs.application.watcher.activated then
            return
        end
        local applies = self:_shouldApply(appName)
        self.log.df("activated event: app='%s' applies=%s", tostring(appName), tostring(applies))
        if not applies then
            return
        end
        self:_raiseAll(app)
    end)
    self._watcher:start()

    local target = #self.appNames == 0 and "all apps" or table.concat(self.appNames, ", ")
    self.log.i("RaiseAllWindows started for: " .. target)
    return self
end


--- RaiseAllWindows:stop()
--- Method
--- Stops watching for application activation events.
function obj:stop()
    if self._watcher then
        self._watcher:stop()
        self._watcher = nil
    end
    self:_stopInputTap()
    return self
end


return obj
