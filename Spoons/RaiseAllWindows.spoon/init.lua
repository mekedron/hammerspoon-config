-------------------------------------------------------------------------------
-- RaiseAllWindows.spoon
--
-- When a configured application becomes active (e.g., via Dock click or
-- Cmd+Tab), raises all of its visible windows above other apps' windows.
-- This restores the older macOS behavior where activating an app brought
-- every one of its windows to the front, not just the most recently
-- focused one.
--
-- Useful for terminal emulators like Ghostty where multiple windows are
-- often open and should all come forward together when switching to the
-- app.
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "RaiseAllWindows"
obj.version = "1.0"

obj.log = hs.logger.new("RaiseAll", "info")

--- RaiseAllWindows.appNames
--- Variable
--- List of application names (as returned by hs.application:name()) for
--- which the raise-all-windows behavior is applied. Set to an empty list
--- {} to apply to every activated app.
obj.appNames = {
    "Ghostty",
}

--- RaiseAllWindows.delay
--- Variable
--- Seconds to wait after an app activation before raising its windows.
--- Lets macOS finish its own window ordering first so our raises stick.
obj.delay = 0.05

obj._watcher = nil
obj._pendingTimer = nil


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
--- Internal: raises every visible standard window of `app`, then re-raises
--- the originally focused window so it stays on top.
function obj:_raiseAll(app)
    if not app or not app:isFrontmost() then
        return
    end

    local focused = app:focusedWindow()
    local windows = app:visibleWindows()
    local focusedId = focused and focused:id() or nil

    self.log.df("Raising %d windows for %s", #windows, app:name())

    for _, win in ipairs(windows) do
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

        if self._pendingTimer then
            self._pendingTimer:stop()
        end
        self._pendingTimer = hs.timer.doAfter(self.delay, function()
            self._pendingTimer = nil
            self:_raiseAll(app)
        end)
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
    if self._pendingTimer then
        self._pendingTimer:stop()
        self._pendingTimer = nil
    end
    if self._watcher then
        self._watcher:stop()
        self._watcher = nil
    end
    return self
end


return obj
