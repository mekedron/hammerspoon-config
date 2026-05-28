-------------------------------------------------------------------------------
-- MiddleClickRightOption.spoon
--
-- Globally watches the middle mouse button. A *fast double middle-click*
-- (two middle-button presses within `doubleClickInterval` seconds) is turned
-- into a held RIGHT Option (⌥) key: Option is pressed down on the second
-- click and released when that second middle button is let go -- a
-- push-to-talk style hold driven entirely by the mouse. A quick double-click
-- (no hold) therefore produces a quick Option tap; a double-click-and-hold
-- holds Option for as long as you keep the button pressed.
--
-- Why right Option specifically: the simulated key carries the right-side
-- device flag (NX_DEVICERALTKEYMASK) on top of the generic Option mask and
-- uses the right-Option virtual keycode (61), so apps that distinguish left
-- vs right Option see the right one.
--
-- Middle-click handling has two modes, selected by `suppressMiddleClick`:
--
--   suppressMiddleClick = true  (default)
--       Every middle press is briefly held back (by doubleClickInterval).
--         * Fast second press -> right Option engages and NO middle click is
--           ever delivered ("instead of a middle click").
--         * Lone middle click  -> replayed as a real middle click after the
--           delay, so ordinary middle-clicking still works (just delayed).
--         * Held middle button -> after the delay a real middle-down is
--           synthesized, so press-and-hold uses (autoscroll, middle-drag)
--           keep working.
--       Cost: every ordinary middle click is delayed by doubleClickInterval.
--
--   suppressMiddleClick = false
--       Ordinary middle clicks fire instantly. The FIRST click of the gesture
--       still performs a real middle click; only the fast SECOND press is
--       swapped for right Option. Snappier, but the first click isn't
--       suppressed.
--
-- Tune `doubleClickInterval` in init.lua to match your click speed.
--
-- Implementation: a single hs.eventtap on otherMouseDown/otherMouseUp.
-- Synthesized events are tagged with a sentinel in the event's
-- eventSourceUserData field so the tap ignores its own posted events instead
-- of reprocessing them (which would loop).
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "MiddleClickRightOption"
obj.version = "1.0"

obj.log = hs.logger.new("MidClkOpt", "info")

--- MiddleClickRightOption.doubleClickInterval
--- Variable
--- Maximum seconds between the two middle-button presses for them to count as
--- a "fast double middle-click". Lower = you must click faster. In suppress
--- mode this is also exactly how long every ordinary middle click is delayed,
--- so there is a real trade-off -- tune to taste.
obj.doubleClickInterval = 0.25

--- MiddleClickRightOption.suppressMiddleClick
--- Variable
--- true  (default): hold every middle press back briefly; a real middle click
---       is never sent for the gesture, and a lone middle click is replayed
---       after `doubleClickInterval`.
--- false: ordinary middle clicks fire instantly; the first click of the
---       gesture stays a real middle click and only the fast second press is
---       swapped for right Option.
obj.suppressMiddleClick = true

--- MiddleClickRightOption.maxHoldSeconds
--- Variable
--- Safety net against a stuck modifier: if right Option has been held this
--- long without the releasing middle-up arriving (e.g. the up event was
--- consumed by another tap), force-release it. Set to 0 to disable. Make it
--- comfortably longer than your longest intended hold.
obj.maxHoldSeconds = 30

-- Middle (center) mouse button number in macOS CGEvents (left=0, right=1).
local MIDDLE_BUTTON = 2

-- kVK_RightOption
local RIGHT_OPTION_KEYCODE = 61
-- kCGEventFlagMaskAlternate (0x00080000) | NX_DEVICERALTKEYMASK (0x00000040):
-- generic "Option is down" plus the right-side device bit.
local RIGHT_OPTION_FLAGS = 0x00080040

-- Sentinel written to synthesized events' source-user-data so our own tap
-- recognizes and ignores them ("MCRO").
local SELF_TAG = 0x4D43524F

local PROPS = hs.eventtap.event.properties
local TYPES = hs.eventtap.event.types

obj._tap = nil
obj._state = "idle"        -- idle | pending | engaged | held
obj._optionDown = false
obj._pendingDownTime = 0
obj._pendingLocation = nil
obj._pendingUpSeen = false
obj._replayTimer = nil
obj._safetyTimer = nil
obj._prevDownTime = 0      -- passthrough mode: time of last real middle-down


function obj:_armSafety()
    self:_disarmSafety()
    if self.maxHoldSeconds and self.maxHoldSeconds > 0 then
        self._safetyTimer = hs.timer.doAfter(self.maxHoldSeconds, function()
            self._safetyTimer = nil
            if self._optionDown then
                self.log.w("max hold reached; force-releasing right Option")
                self:_releaseRightOption()
                self._state = "idle"
            end
        end)
    end
end


function obj:_disarmSafety()
    if self._safetyTimer then
        self._safetyTimer:stop()
        self._safetyTimer = nil
    end
end


function obj:_pressRightOption()
    if self._optionDown then
        return
    end
    self._optionDown = true
    local e = hs.eventtap.event.newKeyEvent({}, RIGHT_OPTION_KEYCODE, true)
    e:rawFlags(RIGHT_OPTION_FLAGS)
    e:post()
    self:_armSafety()
    self.log.i("right Option DOWN")
end


function obj:_releaseRightOption()
    self:_disarmSafety()
    if not self._optionDown then
        return
    end
    self._optionDown = false
    local e = hs.eventtap.event.newKeyEvent({}, RIGHT_OPTION_KEYCODE, false)
    e:rawFlags(0x0)
    e:post()
    self.log.i("right Option UP")
end


function obj:_cancelReplay()
    if self._replayTimer then
        self._replayTimer:stop()
        self._replayTimer = nil
    end
end


--- Posts a synthesized middle-button event, tagged so our own tap passes it
--- straight through to the app instead of reprocessing it.
function obj:_synthMiddle(isDown, point)
    local t = isDown and TYPES.otherMouseDown or TYPES.otherMouseUp
    local e = hs.eventtap.event.newMouseEvent(t, point)
    e:setProperty(PROPS.mouseEventButtonNumber, MIDDLE_BUTTON)
    e:setProperty(PROPS.eventSourceUserData, SELF_TAG)
    e:post()
end


function obj:_onReplayTimeout()
    self._replayTimer = nil
    if self._state ~= "pending" then
        return
    end
    if self._pendingUpSeen then
        -- A lone, completed middle click: deliver it for real (delayed).
        self:_synthMiddle(true, self._pendingLocation)
        self:_synthMiddle(false, self._pendingLocation)
        self._state = "idle"
        self.log.df("replayed lone middle click")
    else
        -- Button is still physically held: begin a real hold so autoscroll /
        -- middle-drag works (just delayed by doubleClickInterval). The real
        -- middle-up will end it (handled in the "held" state below).
        self:_synthMiddle(true, self._pendingLocation)
        self._state = "held"
        self.log.df("middle button held; synthesized middle-down")
    end
end


function obj:_onDown(event)
    local now = hs.timer.secondsSinceEpoch()

    if self.suppressMiddleClick then
        if self._state == "pending"
            and (now - self._pendingDownTime) <= self.doubleClickInterval then
            -- Fast second press: engage right Option, drop the middle click.
            self:_cancelReplay()
            self._state = "engaged"
            self:_pressRightOption()
            return true
        end
        -- Otherwise treat as a (new) first press: swallow and wait to see if a
        -- second one follows quickly.
        self:_cancelReplay()
        self._state = "pending"
        self._pendingDownTime = now
        self._pendingLocation = event:location()
        self._pendingUpSeen = false
        self._replayTimer = hs.timer.doAfter(self.doubleClickInterval, function()
            self:_onReplayTimeout()
        end)
        return true
    end

    -- Passthrough-first mode.
    if self._state ~= "engaged"
        and (now - self._prevDownTime) <= self.doubleClickInterval then
        -- Fast second press: swap this click for right Option.
        self._state = "engaged"
        self:_pressRightOption()
        self._prevDownTime = 0
        return true
    end
    self._prevDownTime = now
    return false  -- let the (first / ordinary) middle click through
end


function obj:_onUp()
    if self._state == "engaged" then
        -- Release of the gesture's second button: drop the hold.
        self:_releaseRightOption()
        self._state = "idle"
        return true
    elseif self._state == "pending" then
        -- Release of the swallowed first press; keep waiting for a 2nd press.
        self._pendingUpSeen = true
        return true
    elseif self._state == "held" then
        -- The real hold we synthesized a down for: let this up end it.
        self._state = "idle"
        return false
    end
    return false
end


function obj:_handle(event)
    -- Ignore events we posted ourselves.
    if event:getProperty(PROPS.eventSourceUserData) == SELF_TAG then
        return false
    end
    -- Only the middle (center) button; back/forward/etc. pass through.
    if event:getProperty(PROPS.mouseEventButtonNumber) ~= MIDDLE_BUTTON then
        return false
    end
    if event:getType() == TYPES.otherMouseDown then
        return self:_onDown(event)
    end
    return self:_onUp()
end


--- MiddleClickRightOption:start()
--- Method
--- Starts the global middle-button event tap.
function obj:start()
    self:stop()
    self._tap = hs.eventtap.new(
        { TYPES.otherMouseDown, TYPES.otherMouseUp },
        function(e) return self:_handle(e) end
    )
    self._tap:start()
    self.log.i(string.format(
        "started (interval=%.0fms, suppress=%s)",
        self.doubleClickInterval * 1000, tostring(self.suppressMiddleClick)
    ))
    return self
end


--- MiddleClickRightOption:stop()
--- Method
--- Stops the event tap, cancels timers, and releases Option if held.
function obj:stop()
    if self._tap then
        self._tap:stop()
        self._tap = nil
    end
    self:_cancelReplay()
    self:_releaseRightOption()
    self._state = "idle"
    return self
end


return obj
