local obj = {}
obj.__index = obj

obj.name = "FifineDisplay"
obj.version = "2.1"
obj.author = "OpenAI"

obj.log = hs.logger.new("FifineDisp", "info")

obj.targetUSBSubstring = "fifine"
obj.externalNameSubstring = "dell"
obj.internalNameSubstring = "built-in"

obj.targetWidth = 2560
obj.targetHeight = 1440

obj.usbWatcher = nil
obj.screenWatcher = nil
obj.pendingTimer = nil
obj.startTimer = nil

local function normalized(s)
  return (s or ""):lower()
end

function obj:_usbMatches(device)
  local product = normalized(device.productName)
  local vendor = normalized(device.vendorName)

  return product:find(self.targetUSBSubstring, 1, true) ~= nil
      or vendor:find(self.targetUSBSubstring, 1, true) ~= nil
end

function obj:_isFifineAttached()
  for _, dev in ipairs(hs.usb.attachedDevices() or {}) do
    if self:_usbMatches(dev) then
      return true
    end
  end
  return false
end

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

function obj:_findInternalScreen()
  for _, screen in ipairs(hs.screen.allScreens()) do
    local name = normalized(screen:name())
    if name:find(self.internalNameSubstring, 1, true) then
      return screen
    end
  end
  return nil
end

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
    if external and currentPrimary ~= external then
      self.log.i("Switching primary -> external")
      local ok = external:setPrimary()
      self.log.i("external:setPrimary() -> " .. tostring(ok))
    end
  else
    if internal and currentPrimary ~= internal then
      self.log.i("Switching primary -> internal")
      local ok = internal:setPrimary()
      self.log.i("internal:setPrimary() -> " .. tostring(ok))
    end
  end
end

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

function obj:start()
  self:stop()

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

  self.screenWatcher = hs.screen.watcher.new(function()
    self:_schedule("screen-change", 2)
  end)

  self.usbWatcher:start()
  self.screenWatcher:start()

  self.startTimer = hs.timer.doAfter(2, function()
    self.startTimer = nil
    self:_apply("startup")
  end)

  hs.alert.show("FifineDisplay started")
  return self
end

function obj:stop()
  if self.pendingTimer then
    self.pendingTimer:stop()
    self.pendingTimer = nil
  end

  if self.startTimer then
    self.startTimer:stop()
    self.startTimer = nil
  end

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
