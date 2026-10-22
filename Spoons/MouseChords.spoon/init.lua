-------------------------------------------------------------------------------
-- MouseChords.spoon
--
-- Mouse chords for dictation and text editing, built on the side buttons
-- (back / forward) and the wheel (middle) button:
--
--   BACK + FORWARD held     Control + Option held for as long as both are held
--                           (VoiceInk's push-to-talk). Letting go of either
--                           releases it.
--   MIDDLE held + BACK      delete the word to the left   (Option+Delete)
--   MIDDLE held + FORWARD   undo                          (Cmd+Z)
--   MIDDLE held + RIGHT     Enter, on a right click with no side button
--   MIDDLE + RIGHT held
--     + BACK                delete one character          (Delete)
--     + FORWARD             jump one word right           (Option+Right)
--   MIDDLE held + wheel     jump one word per wheel step:
--                           up = right, down = left
--   MIDDLE + RIGHT held
--     + wheel               move one character per wheel step
--
-- Holding a side button inside the middle layer auto-repeats its key, except
-- undo, which fires once per click.
--
-- The middle button itself always passes through untouched: PieSwitcher opens
-- its wheel on a middle hold, and middle drags (Blender orbit) must not lag.
-- The spoon only watches whether it is held. Because PieSwitcher sees a plain
-- middle hold, it may open its wheel while a chord is in use; the spoon closes
-- it with a click of an unused mouse button (`pieDismissButton`), which
-- PieSwitcher treats as a click outside the wheel. Apps ignore that button.
--
-- Everyday use keeps working:
--   * a lone side click is still back / forward navigation. It is held back
--     for `chordWindow` seconds to see whether the other side button joins,
--     then replayed;
--   * a right press counts as a modifier only while the middle button is
--     held; otherwise it is untouched.
--
-- Events this spoon posts itself are tagged in eventSourceUserData so the tap
-- passes them through instead of handling them again.
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "MouseChords"
obj.version = "1.0"

obj.log = hs.logger.new("MouseChords", "info")

--- MouseChords.backButton
--- Variable
--- CGEvent button number of the mouse "back" side button (default 3).
obj.backButton = 3

--- MouseChords.forwardButton
--- Variable
--- CGEvent button number of the mouse "forward" side button (default 4).
obj.forwardButton = 4

--- MouseChords.chordWindow
--- Variable
--- Seconds a side press waits for the other side button before it counts as a
--- lone back / forward click (default 0.08). Both buttons pressed "together"
--- land about 30 ms apart.
obj.chordWindow = 0.08

--- MouseChords.pieDismissButton
--- Variable
--- Mouse button number clicked to close PieSwitcher's wheel when a middle
--- chord is used (default 5, a button the mouse doesn't have). nil disables.
obj.pieDismissButton = 5

--- MouseChords.pieHoldDelay
--- Variable
--- Seconds after the middle press by which PieSwitcher has opened its wheel
--- (its hold delay plus a margin, default 0.25). A chord used sooner closes
--- the wheel again once this time is reached.
obj.pieHoldDelay = 0.25

--- MouseChords.repeatDelay
--- Variable
--- Seconds a side button must be held in the middle layer before its key
--- starts repeating (default 0.4).
obj.repeatDelay = 0.4

--- MouseChords.repeatInterval
--- Variable
--- Seconds between repeats (default 0.06). 0 disables auto-repeat.
obj.repeatInterval = 0.06

--- MouseChords.maxHoldSeconds
--- Variable
--- Safety net: force-release Control + Option after this many seconds in case
--- a button-up is missed (default 300). 0 disables.
obj.maxHoldSeconds = 300

--- MouseChords.scrollInterval
--- Variable
--- Minimum seconds between two cursor steps from the wheel (default 0.04), so
--- a burst of smooth-scroll events doesn't fly across the line.
obj.scrollInterval = 0.04

--- MouseChords.invertScroll
--- Variable
--- true: the wheel turn that scrolls a page up moves the cursor right; false
--- swaps the directions.
obj.invertScroll = true

--- MouseChords.actions
--- Variable
--- Keys fired in the middle layer: actions.middle (middle held) and
--- actions.move (middle + right held), each keyed "back" / "forward";
--- actions.rightClick (middle held + right click); actions.scroll (middle
--- held + wheel) and actions.scrollRight (middle + right held + wheel), keyed
--- "up" / "down". `repeats = false` turns off auto-repeat.
obj.actions = {
    middle = {
        back    = { mods = {"alt"}, key = "delete" },
        forward = { mods = {"cmd"}, key = "z", repeats = false },
    },
    move = {
        back    = { mods = {}, key = "delete" },
        forward = { mods = {"alt"}, key = "right" },
    },
    rightClick = { mods = {}, key = "return" },
    scroll = {
        up   = { mods = {"alt"}, key = "left" },
        down = { mods = {"alt"}, key = "right" },
    },
    scrollRight = {
        up   = { mods = {}, key = "left" },
        down = { mods = {}, key = "right" },
    },
}

local PROPS = hs.eventtap.event.properties
local TYPES = hs.eventtap.event.types

local MIDDLE_BUTTON = 2

-- Left Control and left Option keycodes, and the flags a real keyboard sends
-- with them: the generic modifier mask plus the left-side device bit.
local CTRL_KEYCODE = 59
local OPTION_KEYCODE = 58
local CTRL_FLAGS = 0x00040001
local CTRL_OPTION_FLAGS = 0x000C0021

-- Sentinel in eventSourceUserData marking events posted by this spoon ("MCHD").
local SELF_TAG = 0x4D434844

local OTHER_SIDE = { back = "forward", forward = "back" }


function obj:_resetState()
    -- Side button mode: nil (up), "pending" (waiting for a chord), "nav"
    -- (replayed as navigation), "chord" (Control + Option), "layer" (key).
    self._side = { back = {}, forward = {} }
    -- used: a chord fired during this middle hold. downAt: press time.
    self._middle = { down = false, used = false, downAt = 0 }
    -- swallowed: the right press belongs to the middle layer. used: a side
    -- button or the wheel acted during it, so its release is not Enter.
    self._right = { swallowed = false, used = false }
    self._chordHeld = false
    self._lastScrollAction = 0
end

obj._tap = nil
obj._holdSafety = nil
obj._pieTimer = nil
obj:_resetState()


function obj:_buttonNumber(name)
    return name == "forward" and self.forwardButton or self.backButton
end


function obj:_postMouse(button, isDown)
    local t = isDown and TYPES.otherMouseDown or TYPES.otherMouseUp
    local e = hs.eventtap.event.newMouseEvent(t, hs.mouse.absolutePosition())
    e:setProperty(PROPS.mouseEventButtonNumber, button)
    e:setProperty(PROPS.eventSourceUserData, SELF_TAG)
    e:post()
end


function obj:_postKey(keycode, isDown, flags)
    local e = hs.eventtap.event.newKeyEvent({}, keycode, isDown)
    e:rawFlags(flags)
    e:post()
end


function obj:_pressChord()
    if self._chordHeld then return end
    self._chordHeld = true
    self:_postKey(CTRL_KEYCODE, true, CTRL_FLAGS)
    self:_postKey(OPTION_KEYCODE, true, CTRL_OPTION_FLAGS)
    if self.maxHoldSeconds and self.maxHoldSeconds > 0 then
        self._holdSafety = hs.timer.doAfter(self.maxHoldSeconds, function()
            self._holdSafety = nil
            self.log.w("max hold reached; force-releasing Control + Option")
            self:_releaseChord()
        end)
    end
    self.log.i("Control + Option DOWN")
end


function obj:_releaseChord()
    if self._holdSafety then
        self._holdSafety:stop()
        self._holdSafety = nil
    end
    if not self._chordHeld then return end
    self._chordHeld = false
    self:_postKey(OPTION_KEYCODE, false, CTRL_FLAGS)
    self:_postKey(CTRL_KEYCODE, false, 0)
    self.log.i("Control + Option UP")
end


function obj:_fire(action)
    hs.eventtap.event.newKeyEvent(action.mods, action.key, true):post()
    hs.eventtap.event.newKeyEvent(action.mods, action.key, false):post()
end


function obj:_dismissPie()
    if not self.pieDismissButton then return end
    self:_postMouse(self.pieDismissButton, true)
    self:_postMouse(self.pieDismissButton, false)
end


function obj:_cancelPieTimer()
    if self._pieTimer then
        self._pieTimer:stop()
        self._pieTimer = nil
    end
end


--- Marks the current middle hold as a chord and closes PieSwitcher's wheel:
--- now if it is already open, and again once its hold delay has passed if the
--- chord came before the wheel did.
function obj:_useMiddle()
    local m = self._middle
    if m.used then return end
    m.used = true
    self:_dismissPie()
    local remaining = m.downAt + self.pieHoldDelay - hs.timer.secondsSinceEpoch()
    if remaining > 0 then
        self._pieTimer = hs.timer.doAfter(remaining, function()
            self._pieTimer = nil
            if self._middle.down then self:_dismissPie() end
        end)
    end
end


function obj:_stopTimers(s)
    if s.timer then s.timer:stop(); s.timer = nil end
    if s.repeatTimer then s.repeatTimer:stop(); s.repeatTimer = nil end
end


function obj:_startRepeat(s, action)
    if action.repeats == false then return end
    if not (self.repeatInterval and self.repeatInterval > 0) then return end
    s.repeatTimer = hs.timer.doAfter(self.repeatDelay, function()
        s.repeatTimer = hs.timer.doEvery(self.repeatInterval, function()
            self:_fire(action)
        end)
    end)
end


function obj:_sideDown(name)
    local s = self._side[name]
    self:_stopTimers(s)

    if self._middle.down then
        self:_useMiddle()
        s.mode = "layer"
        local layer = self.actions.middle
        if self._right.swallowed then
            self._right.used = true
            layer = self.actions.move
        end
        local action = layer[name]
        self:_fire(action)
        self:_startRepeat(s, action)
        return true
    end

    local other = self._side[OTHER_SIDE[name]]
    if other.mode == "pending" or other.mode == "chord" then
        self:_stopTimers(other)
        other.mode = "chord"
        s.mode = "chord"
        self:_pressChord()
        return true
    end

    s.mode = "pending"
    s.timer = hs.timer.doAfter(self.chordWindow, function()
        s.timer = nil
        if s.mode == "pending" then
            s.mode = "nav"
            self:_postMouse(self:_buttonNumber(name), true)
        end
    end)
    return true
end


function obj:_sideUp(name)
    local s = self._side[name]
    local mode = s.mode
    s.mode = nil
    self:_stopTimers(s)

    if mode == "pending" then
        -- Released inside the chord window: a quick lone click.
        local button = self:_buttonNumber(name)
        self:_postMouse(button, true)
        self:_postMouse(button, false)
        return true
    elseif mode == "chord" then
        self:_releaseChord()
        return true
    elseif mode == "layer" then
        return true
    end
    return false  -- "nav": the replayed down is already out; let the up through
end


function obj:_rightDown()
    if not self._middle.down then return false end
    self:_useMiddle()
    self._right.swallowed = true
    self._right.used = false
    return true
end


function obj:_rightUp()
    local r = self._right
    if not r.swallowed then return false end
    r.swallowed = false
    if not r.used then self:_fire(self.actions.rightClick) end
    return true
end


function obj:_middleScroll(event)
    self:_useMiddle()
    local dy = event:getProperty(PROPS.scrollWheelEventDeltaAxis1)
    if dy == 0 then return true end
    local now = hs.timer.secondsSinceEpoch()
    if now - self._lastScrollAction < self.scrollInterval then return true end
    self._lastScrollAction = now
    local up = (dy > 0) ~= (self.invertScroll == true)
    local layer = self.actions.scroll
    if self._right.swallowed then
        self._right.used = true
        layer = self.actions.scrollRight
    end
    self:_fire(layer[up and "up" or "down"])
    return true
end


function obj:_handle(event)
    if event:getProperty(PROPS.eventSourceUserData) == SELF_TAG then
        return false
    end
    local etype = event:getType()

    if etype == TYPES.scrollWheel then
        if not self._middle.down then return false end
        return self:_middleScroll(event)
    elseif etype == TYPES.rightMouseDown then
        return self:_rightDown()
    elseif etype == TYPES.rightMouseUp then
        return self:_rightUp()
    end

    local n = event:getProperty(PROPS.mouseEventButtonNumber)
    if n == MIDDLE_BUTTON then
        local m = self._middle
        if etype == TYPES.otherMouseDown then
            m.down, m.used = true, false
            m.downAt = hs.timer.secondsSinceEpoch()
        elseif etype == TYPES.otherMouseUp then
            m.down = false
            self:_cancelPieTimer()
        end
        return false
    end

    local name = (n == self.backButton and "back")
        or (n == self.forwardButton and "forward")
        or nil
    if not name then return false end
    if etype == TYPES.otherMouseDown then return self:_sideDown(name) end
    if etype == TYPES.otherMouseUp then return self:_sideUp(name) end
    -- Side-button drags: swallow while we own the press.
    return self._side[name].mode ~= nil and self._side[name].mode ~= "nav"
end


--- MouseChords:start()
--- Method
--- Starts the global mouse event tap.
function obj:start()
    self:stop()
    self._tap = hs.eventtap.new({
        TYPES.rightMouseDown, TYPES.rightMouseUp,
        TYPES.otherMouseDown, TYPES.otherMouseUp, TYPES.otherMouseDragged,
        TYPES.scrollWheel,
    }, function(e) return self:_handle(e) end)
    self._tap:start()
    self.log.i(string.format("started (back=%d, forward=%d)",
        self.backButton, self.forwardButton))
    return self
end


--- MouseChords:stop()
--- Method
--- Stops the event tap, cancels timers and releases a held Control + Option.
function obj:stop()
    if self._tap then
        self._tap:stop()
        self._tap = nil
    end
    for _, s in pairs(self._side) do self:_stopTimers(s) end
    self:_cancelPieTimer()
    self:_releaseChord()
    self:_resetState()
    return self
end


return obj
