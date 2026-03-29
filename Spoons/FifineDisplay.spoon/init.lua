-------------------------------------------------------------------------------
-- FifineDisplay.spoon
--
-- Manages primary display and window placement based on the connection state
-- of a Fifine USB microphone.
--
-- Context: A Dell monitor (2560x1440) is shared between two laptops using
-- different input sources (HDMI for this Mac, DisplayPort for the other).
-- The Fifine microphone is USB-connected to this Mac, so its presence
-- indicates that the Dell monitor is actively displaying this Mac's output.
--
-- Behavior:
--   Microphone connected   -> Dell is the active display for this Mac
--                           -> Set Dell as primary screen
--   Microphone disconnected -> Dell switched to the other laptop's input
--                           -> Set built-in screen as primary
--                           -> Move all windows to the built-in screen
--
-- The spoon monitors both USB events and screen configuration changes,
-- with debounced scheduling to handle rapid successive events. Window
-- moves are retried at multiple intervals because macOS takes variable
-- time to reconfigure display geometry after a primary screen change.
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "FifineDisplay"
obj.version = "3.0"
obj.author = "OpenAI"

-- Logger for debugging display/USB events (Console.app or hs.openConsole())
obj.log = hs.logger.new("FifineDisp", "info")

-- USB device identifier: matches against product/vendor name (case-insensitive)
obj.targetUSBSubstring = "fifine"
-- Screen name identifiers (case-insensitive substrings)
obj.externalNameSubstring = "dell"
obj.internalNameSubstring = "built-in"

-- Expected resolution of the external Dell monitor, used to disambiguate
-- in case multiple displays match the name substring
obj.targetWidth = 2560
obj.targetHeight = 1440

-- Watchers and timers (managed by start/stop lifecycle)
obj.usbWatcher = nil      -- Monitors USB connect/disconnect events
obj.screenWatcher = nil    -- Monitors display configuration changes
obj.pendingTimer = nil     -- Debounce timer for coalescing rapid events
obj.startTimer = nil       -- One-shot timer for initial state on startup
obj.moveTimers = {}        -- Timers for delayed window moves (retries)


--- Lowercases a string for case-insensitive comparison.
--- Returns empty string if input is nil.
local function normalized(s)
  return (s or ""):lower()
end


--- Checks whether a USB device event matches the Fifine microphone
--- by searching both productName and vendorName.
function obj:_usbMatches(device)
  local product = normalized(device.productName)
  local vendor = normalized(device.vendorName)

  return product:find(self.targetUSBSubstring, 1, true) ~= nil
      or vendor:find(self.targetUSBSubstring, 1, true) ~= nil
end


--- Scans all currently attached USB devices to check if a Fifine device
--- is present. Returns true if found, false otherwise.
function obj:_isFifineAttached()
  for _, dev in ipairs(hs.usb.attachedDevices() or {}) do
    if self:_usbMatches(dev) then
      return true
    end
  end
  return false
end


--- Finds the external Dell screen among all connected displays.
--- Matches by name substring AND expected resolution to avoid false positives.
--- Returns the hs.screen object or nil if not found.
function obj:_findExternalScreen()
  for _, screen in ipairs(hs.screen.allScreens()) do
    local name = normalized(screen:name())
    local mode = screen:currentMode()

    if name:find(self.externalNameSubstring, 1, true) and mode then
      if mode.w == self.targetWidth and mode.h == self.targetHeight then
        return screen
      end
    end
  end
  return nil
end


--- Finds the built-in MacBook screen among all connected displays.
--- Returns the hs.screen object or nil if not found.
function obj:_findInternalScreen()
  for _, screen in ipairs(hs.screen.allScreens()) do
    local name = normalized(screen:name())
    if name:find(self.internalNameSubstring, 1, true) then
      return screen
    end
  end
  return nil
end


--- Logs all connected screens with their names, UUIDs, and current modes.
--- Useful for debugging display detection issues.
function obj:_debugScreens(prefix)
  for _, screen in ipairs(hs.screen.allScreens()) do
    local mode = screen:currentMode() or {}
    self.log.i(string.format(
      "%s screen=%s uuid=%s mode=%sx%s scale=%s",
      tostring(prefix),
      tostring(screen:name()),
      tostring(screen:getUUID()),
      tostring(mode.w),
      tostring(mode.h),
      tostring(mode.scale)
    ))
  end
end


--- Moves all standard (non-system) windows to the specified target screen.
--- Windows already on the target screen are left untouched.
function obj:_moveAllWindowsToScreen(targetScreen)
  if not targetScreen then
    self.log.w("moveAllWindows: target screen is nil, skipping")
    return
  end

  local moved = 0
  for _, win in ipairs(hs.window.allWindows()) do
    -- Only move standard, visible application windows
    -- (skip system UI elements like menu bar, dock, Spotlight, etc.)
    if win:isStandard() and win:screen() ~= targetScreen then
      win:moveToScreen(targetScreen, false, true)
      moved = moved + 1
    end
  end
  self.log.i(string.format("Moved %d windows to %s", moved, targetScreen:name()))
end


--- Cancels any pending window-move timers to prevent stale moves
--- from executing after conditions have changed.
function obj:_cancelMoveTimers()
  for _, timer in ipairs(self.moveTimers) do
    if timer and timer:running() then
      timer:stop()
    end
  end
  self.moveTimers = {}
end


--- Schedules window moves to the built-in screen at multiple delay intervals.
--- Multiple attempts are needed because macOS takes variable time to
--- reconfigure display geometry after a primary screen change. The first
--- attempt catches most windows; later attempts pick up any that were
--- missed due to timing.
function obj:_scheduleMoveWindows()
  self:_cancelMoveTimers()

  -- Attempt window moves at 1s, 2.5s, and 4s after the primary switch.
  -- This covers both fast and slow macOS display reconfigurations.
  local delays = { 1, 2.5, 4 }

  for _, delay in ipairs(delays) do
    local timer = hs.timer.doAfter(delay, function()
      self.log.i(string.format("Attempting window move (delay=%.1fs)", delay))
      -- Re-find the internal screen each time in case screens were
      -- reconfigured between attempts
      local screen = self:_findInternalScreen()
      if screen then
        self:_moveAllWindowsToScreen(screen)
      else
        self.log.w("Internal screen not found for window move")
      end
    end)
    table.insert(self.moveTimers, timer)
  end
end


--- Core logic: determines the desired state based on Fifine microphone
--- presence and applies the appropriate primary screen setting.
---
--- When Fifine is attached:
---   Dell is displaying this Mac -> make Dell primary
--- When Fifine is detached:
---   Dell switched to other input -> make built-in primary
---   Move all windows to built-in (with retries for timing)
function obj:_apply(reason)
  local fifine = self:_isFifineAttached()
  local external = self:_findExternalScreen()
  local internal = self:_findInternalScreen()
  local currentPrimary = hs.screen.primaryScreen()

  self.log.i(string.format(
    "apply reason=%s fifine=%s external=%s internal=%s currentPrimary=%s",
    tostring(reason),
    tostring(fifine),
    external and external:name() or "nil",
    internal and internal:name() or "nil",
    currentPrimary and currentPrimary:name() or "nil"
  ))

  self:_debugScreens("debug")

  if fifine then
    -- Microphone present: Dell is on HDMI for this Mac -> make it primary
    self:_cancelMoveTimers()
    if external and currentPrimary ~= external then
      self.log.i("Switching primary -> external")
      local ok = external:setPrimary()
      self.log.i("external:setPrimary() -> " .. tostring(ok))
    end
  else
    -- Microphone absent: Dell switched to other laptop -> use built-in
    if internal then
      if currentPrimary ~= internal then
        self.log.i("Switching primary -> internal")
        local ok = internal:setPrimary()
        self.log.i("internal:setPrimary() -> " .. tostring(ok))
      end

      -- Move all windows to built-in screen. Scheduled with multiple
      -- retries because macOS needs time to reconfigure display geometry
      -- after a primary screen change. Without this delay, moveToScreen()
      -- may use stale screen coordinates and place windows incorrectly.
      self:_scheduleMoveWindows()
    end
  end
end


--- Debounces _apply calls: cancels any pending timer and schedules a new
--- _apply after the given delay. This prevents rapid-fire events (e.g.,
--- multiple USB or screen change notifications) from causing redundant work.
function obj:_schedule(reason, delay)
  if self.pendingTimer then
    self.pendingTimer:stop()
    self.pendingTimer = nil
  end

  self.pendingTimer = hs.timer.doAfter(delay or 2, function()
    self.pendingTimer = nil
    self:_apply(reason)
  end)
end


--- Starts all watchers and applies the initial state.
--- Safe to call multiple times (calls stop() first to clean up).
function obj:start()
  self:stop()

  -- Watch for USB connect/disconnect events matching the Fifine microphone
  self.usbWatcher = hs.usb.watcher.new(function(event)
    if not self:_usbMatches(event) then
      return
    end

    self.log.i(string.format(
      "USB event=%s product=%s vendor=%s",
      tostring(event.eventType),
      tostring(event.productName),
      tostring(event.vendorName)
    ))

    if event.eventType == "added" then
      self:_schedule("usb-added", 2)
    elseif event.eventType == "removed" then
      self:_schedule("usb-removed", 2)
    end
  end)

  -- Watch for screen configuration changes (display added/removed/reconfigured).
  -- This catches cases where the Dell monitor appears or disappears without a
  -- corresponding USB event, or where macOS reconfigures after wake from sleep.
  self.screenWatcher = hs.screen.watcher.new(function()
    self:_schedule("screen-change", 2)
  end)

  self.usbWatcher:start()
  self.screenWatcher:start()

  -- Apply initial state after a short delay to let the system settle on startup.
  -- This handles the case where Hammerspoon is reloaded while the microphone is
  -- already connected or disconnected.
  self.startTimer = hs.timer.doAfter(2, function()
    self.startTimer = nil
    self:_apply("startup")
  end)

  return self
end


--- Stops all watchers and cancels all pending timers.
function obj:stop()
  if self.pendingTimer then
    self.pendingTimer:stop()
    self.pendingTimer = nil
  end

  if self.startTimer then
    self.startTimer:stop()
    self.startTimer = nil
  end

  self:_cancelMoveTimers()

  if self.usbWatcher then
    self.usbWatcher:stop()
    self.usbWatcher = nil
  end

  if self.screenWatcher then
    self.screenWatcher:stop()
    self.screenWatcher = nil
  end

  return self
end

return obj
