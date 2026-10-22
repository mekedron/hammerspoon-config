-------------------------------------------------------------------------------
-- MouseChords.spoon
--
-- Mouse chords for dictation and word editing, built on the side buttons
-- (back / forward) and the wheel (middle) button:
--
--   BACK + FORWARD held     Control + Option held for as long as both are held
--                           (VoiceInk's push-to-talk). Letting go of either
--                           releases it.
--   MIDDLE held + BACK      delete the word to the left   (Option+Delete)
--   MIDDLE held + FORWARD   undo                          (Cmd+Z)
--   MIDDLE + RIGHT held
--     + BACK                jump one word left            (Option+Left)
--     + FORWARD             jump one word right           (Option+Right)
--
--   MIDDLE held + wheel     move the cursor one character per wheel step:
--                           up = left, down = right
--
-- Holding a side button inside the middle layer auto-repeats its key, except
-- undo, which fires once per click.
--
-- Everyday use keeps working:
--   * a lone side click is still back / forward navigation. It is held back
--     for `chordWindow` seconds to see whether the other side button joins,
--     then replayed;
--   * a lone middle click is replayed on release;
--   * a middle drag (Blender orbit, autoscroll) is replayed as soon as the
--     pointer moves more than `dragThreshold` pixels, so the drag goes through;
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

--- MouseChords.dragThreshold
--- Variable
--- Pixels the pointer may move with the middle button held before the press is
--- treated as a middle drag and replayed to the app (default 4).
obj.dragThreshold = 4

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
--- false: the wheel turn that scrolls a page up moves the cursor left. Set
--- true if the directions come out swapped with your scroll settings.
obj.invertScroll = false

--- MouseChords.actions
--- Variable
--- Keys fired in the middle layer: actions.middle (middle held),
--- actions.move (middle + right held), each keyed "back" / "forward", and
--- actions.scroll (middle held + wheel), keyed "up" / "down".
obj.actions = {
    middle = {
        back    = { mods = {"alt"}, key = "delete" },
        forward = { mods = {"cmd"}, key = "z", repeats = false },
    },
    move = {
        back    = { mods = {"alt"}, key = "left" },
        forward = { mods = {"alt"}, key = "right" },
    },
    scroll = {
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
    self._middle = { down = false, used = false, replayed = false, loc = nil }
    self._rightSwallowed = false
    self._chordHeld = false
end

obj._tap = nil
obj._holdSafety = nil
obj:_resetState()


function obj:_buttonNumber(name)
    return name == "forward" and self.forwardButton or self.backButton
end


function obj:_postMouse(button, isDown, loc)
    local t = isDown and TYPES.otherMouseDown or TYPES.otherMouseUp
    local e = hs.eventtap.event.newMouseEvent(t, loc or hs.mouse.absolutePosition())
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
        self._middle.used = true
        s.mode = "layer"
        local layer = self._rightSwallowed and self.actions.move or self.actions.middle
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


function obj:_middleDown(event)
    local m = self._middle
    m.down, m.used, m.replayed = true, false, false
    m.loc = event:location()
    -- Replays reuse a copy of the real press so it keeps its event number;
    -- the window server pairs the real release with it.
    m.downEvent = event:copy()
    m.downEvent:setProperty(PROPS.eventSourceUserData, SELF_TAG)
    return true
end


function obj:_middleDragged(event)
    local m = self._middle
    if not m.down or m.replayed then return false end
    if m.used then return true end
    local p = event:location()
    if math.abs(p.x - m.loc.x) <= self.dragThreshold
        and math.abs(p.y - m.loc.y) <= self.dragThreshold then
        return true
    end
    -- A real middle drag: replay the press; the following drags and the
    -- release pass through untouched.
    m.replayed = true
    m.downEvent:post()
    return true
end


function obj:_middleUp()
    local m = self._middle
    m.down = false
    if m.used then return true end
    if m.replayed then return false end
    self:_postMouse(MIDDLE_BUTTON, true, m.loc)
    self:_postMouse(MIDDLE_BUTTON, false, m.loc)
    return true
end


function obj:_middleScroll(event)
    self._middle.used = true
    local dy = event:getProperty(PROPS.scrollWheelEventDeltaAxis1)
    if dy == 0 then return true end
    local now = hs.timer.secondsSinceEpoch()
    if now - (self._lastScrollAction or 0) < self.scrollInterval then return true end
    self._lastScrollAction = now
    local up = (dy > 0) ~= (self.invertScroll == true)
    self:_fire(self.actions.scroll[up and "up" or "down"])
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
        if not self._middle.down then return false end
        self._middle.used = true
        self._rightSwallowed = true
        return true
    elseif etype == TYPES.rightMouseUp then
        if not self._rightSwallowed then return false end
        self._rightSwallowed = false
        return true
    end

    local n = event:getProperty(PROPS.mouseEventButtonNumber)
    if n == MIDDLE_BUTTON then
        if etype == TYPES.otherMouseDown then return self:_middleDown(event) end
        if etype == TYPES.otherMouseUp then return self:_middleUp() end
        return self:_middleDragged(event)
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
    self:_releaseChord()
    self:_resetState()
    return self
end


return obj
