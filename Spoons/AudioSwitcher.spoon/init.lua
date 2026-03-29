-------------------------------------------------------------------------------
-- AudioSwitcher.spoon
--
-- Automatically switches default audio input and output devices based on
-- configurable priority lists. When devices are connected or disconnected,
-- the highest-priority available device is selected.
--
-- Device matching uses case-insensitive partial name matching, so device
-- names don't need to be exact -- just unique enough to identify the device.
--
-- Default priorities:
--   Input:  Fifine mic > MacBook Pro Microphone
--   Output: USB-C to 3.5mm adapter > External Headphones > MacBook Pro Speakers
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "AudioSwitcher"
obj.version = "1.0"

obj.log = hs.logger.new("AudioSwitch", "info")

--- AudioSwitcher.inputPriority
--- Variable
--- Ordered list of input device name patterns (case-insensitive, partial match).
--- First available match wins.
obj.inputPriority = {
    "fifine",
    "macbook pro microphone",
}

--- AudioSwitcher.outputPriority
--- Variable
--- Ordered list of output device name patterns (case-insensitive, partial match).
--- First available match wins.
obj.outputPriority = {
    "usb-c to 3.5mm",
    "external headphones",
    "macbook pro speakers",
}

obj._pendingTimer = nil
obj._startTimer = nil
obj._normalizedInput = nil
obj._normalizedOutput = nil


local function normalized(s)
    return (s or ""):lower()
end


--- Finds the highest-priority available device from the given device list.
--- Returns the device object or nil.
function obj:_findBest(devices, patterns)
    for _, pattern in ipairs(patterns) do
        for _, device in ipairs(devices) do
            if normalized(device:name()):find(pattern, 1, true) then
                return device
            end
        end
    end
    return nil
end


--- Logs all available audio devices for debugging.
function obj:_logDevices()
    self.log.i("-- Available input devices --")
    for _, d in ipairs(hs.audiodevice.allInputDevices()) do
        self.log.i("  input: " .. d:name())
    end
    self.log.i("-- Available output devices --")
    for _, d in ipairs(hs.audiodevice.allOutputDevices()) do
        self.log.i("  output: " .. d:name())
    end
end


--- Evaluates current devices and switches to the highest-priority available
--- device for both input and output.
function obj:_apply(reason)
    self.log.i("Applying audio priorities, reason=" .. tostring(reason))
    self:_logDevices()

    local currentInput = hs.audiodevice.defaultInputDevice()
    local bestInput = self:_findBest(
        hs.audiodevice.allInputDevices(),
        self._normalizedInput
    )

    if bestInput then
        if not currentInput or currentInput:name() ~= bestInput:name() then
            self.log.i("Switching input -> " .. bestInput:name())
            bestInput:setDefaultInputDevice()
        else
            self.log.i("Input already correct: " .. bestInput:name())
        end
    end

    local currentOutput = hs.audiodevice.defaultOutputDevice()
    local bestOutput = self:_findBest(
        hs.audiodevice.allOutputDevices(),
        self._normalizedOutput
    )

    if bestOutput then
        if not currentOutput or currentOutput:name() ~= bestOutput:name() then
            self.log.i("Switching output -> " .. bestOutput:name())
            bestOutput:setDefaultOutputDevice()
        else
            self.log.i("Output already correct: " .. bestOutput:name())
        end
    end
end


--- Debounces _apply calls to coalesce rapid device change events.
function obj:_schedule(reason, delay)
    if self._pendingTimer then
        self._pendingTimer:stop()
        self._pendingTimer = nil
    end

    self._pendingTimer = hs.timer.doAfter(delay or 1, function()
        self._pendingTimer = nil
        self:_apply(reason)
    end)
end


--- AudioSwitcher:start()
--- Method
--- Starts watching for audio device changes and applies initial priorities.
function obj:start()
    self:stop()

    -- Pre-normalize priority patterns
    self._normalizedInput = {}
    for _, p in ipairs(self.inputPriority) do
        table.insert(self._normalizedInput, normalized(p))
    end
    self._normalizedOutput = {}
    for _, p in ipairs(self.outputPriority) do
        table.insert(self._normalizedOutput, normalized(p))
    end

    hs.audiodevice.watcher.setCallback(function(event)
        self.log.i("Audio event: " .. tostring(event))
        if event == "dev#" then
            self:_schedule("device-change", 1)
        end
    end)
    hs.audiodevice.watcher.start()

    self._startTimer = hs.timer.doAfter(1, function()
        self._startTimer = nil
        self:_apply("startup")
    end)

    self.log.i("AudioSwitcher started")
    return self
end


--- AudioSwitcher:stop()
--- Method
--- Stops watching for audio device changes.
function obj:stop()
    if self._pendingTimer then
        self._pendingTimer:stop()
        self._pendingTimer = nil
    end

    if self._startTimer then
        self._startTimer:stop()
        self._startTimer = nil
    end

    if hs.audiodevice.watcher.isRunning() then
        hs.audiodevice.watcher.stop()
    end

    return self
end

return obj
