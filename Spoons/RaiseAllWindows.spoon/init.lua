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
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "RaiseAllWindows"
obj.version = "2.0"

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

obj._watcher = nil


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


--- RaiseAllWindows:_raiseAll(app)
--- Internal: raises every visible window of `app` atomically via the
--- AppKit "activate all windows" option.
function obj:_raiseAll(app)
    if not app then
        return
    end

    -- NSRunningApplication.activateWithOptions:NSApplicationActivateAllWindows
    -- One OS call, applied atomically by the WindowServer.
    local ok = app:activate(true)
    self.log.df("activate(allWindows=true) -> %s for %s", tostring(ok), app:name())

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

    self._watcher = hs.application.watcher.new(function(appName, eventType, app)
        if eventType ~= hs.application.watcher.activated then
            return
        end
        if not self:_shouldApply(appName) then
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
    return self
end


return obj
