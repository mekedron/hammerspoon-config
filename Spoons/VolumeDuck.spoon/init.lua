-------------------------------------------------------------------------------
-- VolumeDuck.spoon
--
-- Push-to-duck: while Control + Option are held together (and nothing else),
-- the system output volume drops to `duckVolume` percent, so every sound
-- source on the Mac gets quieter at once. Releasing either key restores the
-- volume it had before.
--
-- Ctrl+Option is also the prefix of many shortcuts (window managers,
-- VoiceOver, app bindings). To keep those from dipping the sound:
--   * ducking starts only after the combo has been held alone for
--     `holdDelay` seconds, so a quick Ctrl+Option+<key> never ducks;
--   * pressing any other key while ducked restores the volume immediately,
--     and the combo stays inert until both modifiers are released.
--
-- macOS has no per-app volume, so "all sources" means the default output
-- device's volume. Devices without a software volume control (most HDMI /
-- DisplayPort outputs) report no volume and are left alone.
--
-- Stuck-volume guards:
--   * while ducked, a poll checks the real modifier state, so a missed
--     flagsChanged event (tap disabled by the system, secure input) still
--     restores the volume;
--   * the pre-duck volume is persisted in hs.settings, so a Hammerspoon
--     reload or crash mid-duck restores it on the next start.
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "VolumeDuck"
obj.version = "1.0"

obj.log = hs.logger.new("VolumeDuck", "info")

--- VolumeDuck.duckVolume
--- Variable
--- Output volume (0-100) while the combo is held. A volume already at or below
--- this level is left unchanged, so ducking never makes anything louder.
obj.duckVolume = 20

--- VolumeDuck.holdDelay
--- Variable
--- Seconds Ctrl+Option must be held with no other key before the volume drops.
--- Keeps quick Ctrl+Option+<key> shortcuts from ducking. 0 = duck instantly.
obj.holdDelay = 0.15

--- VolumeDuck.pollInterval
--- Variable
--- While ducked, how often (seconds) the real modifier state is re-checked as a
--- fallback in case the key-release event is missed.
obj.pollInterval = 0.5

local SETTINGS_KEY = "VolumeDuck.pending"

local TYPES = hs.eventtap.event.types

obj._tap = nil
obj._armTimer = nil
obj._pollTimer = nil
-- idle | arming (combo held, waiting holdDelay) | ducked | spent (combo
-- used for a shortcut; inert until both modifiers are released)
obj._state = "idle"
obj._device = nil
obj._savedVolume = nil


-- True when exactly Control + Option are down (Fn is ignored: it rides along
-- on arrow/function keys and some keyboards report it spuriously).
local function comboHeld(flags)
    return flags.ctrl and flags.alt and not flags.cmd and not flags.shift
end


local function anyModifier(flags)
    return flags.ctrl or flags.alt or flags.cmd or flags.shift
end


function obj:_stopTimer(name)
    if self[name] then
        self[name]:stop()
        self[name] = nil
    end
end


function obj:_duck()
    local device = hs.audiodevice.defaultOutputDevice()
    local volume = device and device:outputVolume()
    if not volume then
        self.log.i("output device has no software volume; not ducking")
        self._state = "spent"
        return
    end

    self._state = "ducked"
    if volume <= self.duckVolume then
        return
    end

    self._device = device
    self._savedVolume = volume
    hs.settings.set(SETTINGS_KEY, { uid = device:uid(), volume = volume })
    device:setOutputVolume(self.duckVolume)
    self.log.i(string.format("ducked %s: %.0f -> %d", device:name(), volume, self.duckVolume))

    self._pollTimer = hs.timer.doEvery(self.pollInterval, function()
        if not comboHeld(hs.eventtap.checkKeyboardModifiers()) then
            self:_reset()
        end
    end)
end


-- Restores the volume on the device that was ducked, even if the default
-- output changed in between (AudioSwitcher, headphones unplugged).
function obj:_restore()
    self:_stopTimer("_pollTimer")
    if not self._savedVolume then
        -- Nothing ducked by this run; the persisted entry (if any) belongs to
        -- a previous run and is _restorePending's to consume.
        return
    end
    self._device:setOutputVolume(self._savedVolume)
    self.log.i(string.format("restored %s -> %.0f", self._device:name(), self._savedVolume))
    self._device = nil
    self._savedVolume = nil
    hs.settings.clear(SETTINGS_KEY)
end


function obj:_reset()
    self:_stopTimer("_armTimer")
    self:_restore()
    self._state = "idle"
end


function obj:_onFlagsChanged(flags)
    if comboHeld(flags) then
        if self._state == "idle" then
            self._state = "arming"
            if self.holdDelay > 0 then
                self._armTimer = hs.timer.doAfter(self.holdDelay, function()
                    self._armTimer = nil
                    if self._state == "arming" then
                        self:_duck()
                    end
                end)
            else
                self:_duck()
            end
        end
    elseif self._state == "spent" then
        if not anyModifier(flags) then
            self._state = "idle"
        end
    elseif self._state ~= "idle" then
        self:_reset()
        -- Ctrl+Option widened to e.g. Ctrl+Option+Shift: treat the rest of
        -- this press as a shortcut, not a duck.
        if flags.cmd or flags.shift then
            self._state = "spent"
        end
    end
end


function obj:_onKeyDown()
    if self._state == "arming" or self._state == "ducked" then
        self:_stopTimer("_armTimer")
        self:_restore()
        self._state = "spent"
    end
end


-- Restores a volume left ducked by a previous run that never got to release.
function obj:_restorePending()
    local pending = hs.settings.get(SETTINGS_KEY)
    if type(pending) ~= "table" then
        return
    end
    hs.settings.clear(SETTINGS_KEY)
    local device = pending.uid and hs.audiodevice.findDeviceByUID(pending.uid)
    if device and pending.volume then
        device:setOutputVolume(pending.volume)
        self.log.i(string.format("restored %s -> %.0f after restart", device:name(), pending.volume))
    end
end


--- VolumeDuck:start()
--- Method
--- Starts watching Control + Option.
function obj:start()
    self:stop()
    self:_restorePending()

    self._tap = hs.eventtap.new({ TYPES.flagsChanged, TYPES.keyDown }, function(event)
        if event:getType() == TYPES.flagsChanged then
            self:_onFlagsChanged(event:getFlags())
        else
            self:_onKeyDown()
        end
        return false
    end)
    self._tap:start()

    self.log.i("VolumeDuck started")
    return self
end


--- VolumeDuck:stop()
--- Method
--- Stops watching and restores the volume if it is currently ducked.
function obj:stop()
    if self._tap then
        self._tap:stop()
        self._tap = nil
    end
    self:_reset()
    return self
end

return obj
