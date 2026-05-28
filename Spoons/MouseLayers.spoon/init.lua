-------------------------------------------------------------------------------
-- MouseLayers.spoon
--
-- Gives the mouse's side buttons (the ones that normally do web back/forward)
-- three roles each, without losing their everyday navigation:
--
--   SINGLE click          passes through as the normal back/forward navigation
--                         (replayed after `doubleClickInterval`, so there is a
--                         small, deliberate delay -- see below).
--   DOUBLE click (fast)   fires a key: forward = Enter, back = Escape.
--   HOLD + click another  the side button becomes a modifier LAYER, remapping
--     button              the main mouse buttons while you hold it:
--
--       FORWARD held          left=Left, right=Right, middle=Backspace
--       BACK held             left=⌥Left, right=⌥Right, middle=⌥Backspace
--                             (word-wise cursor jump / delete-word)
--       FORWARD + BACK held   right Option (⌥) held down for as long as both
--                             are held (push-to-talk style)
--
-- Because a single click must still be delivered as real navigation, every
-- side-button press is briefly held back: if a second click arrives within
-- `doubleClickInterval` it becomes the double-click key; if you click another
-- button while holding, it becomes the modifier layer; otherwise, once the
-- window passes, the original click is replayed as a real back/forward nav.
--
-- Button numbers (mouseEventButtonNumber) vary by mouse. The common 5-button
-- convention is back=3, forward=4. If yours differs, set logButtons = true,
-- reload, click each side button, and read the number from the Hammerspoon
-- console, then set backButton / forwardButton.
--
-- Implementation: one hs.eventtap on the left/right/other mouse down+up events.
-- Replayed nav clicks are tagged in eventSourceUserData with a sentinel so the
-- tap ignores its own posted events instead of reprocessing them.
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "MouseLayers"
obj.version = "1.0"

obj.log = hs.logger.new("MouseLayers", "info")

--- MouseLayers.backButton
--- Variable
--- CGEvent button number of the mouse "back" side button (default 3).
obj.backButton = 3

--- MouseLayers.forwardButton
--- Variable
--- CGEvent button number of the mouse "forward" side button (default 4).
obj.forwardButton = 4

--- MouseLayers.doubleClickInterval
--- Variable
--- Seconds to hold a single side-button click back while watching for a fast
--- second click (default 0.25). A lone click is replayed as real back/forward
--- navigation after this delay; a second click within it fires the key action.
obj.doubleClickInterval = 0.25

--- MouseLayers.repeatDelay
--- Variable
--- Seconds a mapped (layer) button must be held before its key-action starts
--- repeating (default 0.4). A click released sooner fires exactly once.
obj.repeatDelay = 0.4

--- MouseLayers.repeatInterval
--- Variable
--- Seconds between repeats once auto-repeat has kicked in (default 0.05 = 20/s).
--- Set to 0 to disable auto-repeat entirely (one keypress per click).
obj.repeatInterval = 0.05

--- MouseLayers.maxRepeatSeconds
--- Variable
--- Safety cap: force-stop a layer-key repeat after this long in case the
--- releasing button-up is somehow missed (default 10). 0 disables the cap.
obj.maxRepeatSeconds = 10

--- MouseLayers.maxHoldSeconds
--- Variable
--- Safety net for the Forward+Back held right Option: if the releasing button-up
--- is somehow missed, force-release Option after this long (default 30). 0
--- disables.
obj.maxHoldSeconds = 30

--- MouseLayers.logButtons
--- Variable
--- When true, log the button number of every "other" mouse press so you can
--- discover your mouse's back/forward numbers. Leave false in normal use.
obj.logButtons = false

--- MouseLayers.layers
--- Variable
--- The layer -> button -> action map. Built from defaults on start() if unset.
--- Each action is either a keystroke { mods = {...}, key = "left", repeats =
--- true } or a function { fn = function() ... end, repeats = false }. Override
--- before :start() to customize. layers.FB is the forward+back combo layer.
obj.layers = nil

--- MouseLayers.doubleClickActions
--- Variable
--- Per-side-button action fired on a fast double-click. Keyed "forward" /
--- "back". Built from defaults on start() if unset.
obj.doubleClickActions = nil

local PROPS = hs.eventtap.event.properties
local TYPES = hs.eventtap.event.types

-- Which event types are "button down" (vs up).
local DOWN = {
    [TYPES.leftMouseDown]  = true,
    [TYPES.rightMouseDown] = true,
    [TYPES.otherMouseDown] = true,
}

local MIDDLE_BUTTON = 2

-- Right Option synthesis (matches MiddleClickRightOption): right-Option keycode
-- plus generic Option mask | right-side device bit.
local RIGHT_OPTION_KEYCODE = 61
local RIGHT_OPTION_FLAGS = 0x00080040

-- Sentinel in eventSourceUserData marking our own replayed nav clicks ("MLYR").
local SELF_TAG = 0x4D4C5952


obj._tap = nil
obj._down = { forward = false, back = false }        -- side button held?
obj._used = { forward = false, back = false }        -- used as a modifier?
obj._pending = { forward = false, back = false }     -- awaiting a 2nd click?
obj._navConsumed = { forward = false, back = false } -- double fired; eat the up
obj._replayTimer = {}      -- side button -> single-click replay timer
obj._swallowed = {}        -- action button -> we consumed its down
obj._repeat = {}           -- action button -> active repeat timer
obj._safety = {}           -- action button -> repeat safety timer
obj._optionDown = false    -- right Option held (forward+back combo)?
obj._holdSafety = nil      -- safety timer for a stuck held Option


function obj:_defaultLayers()
    return {
        F = {
            left   = { mods = {},      key = "left",   repeats = true },
            right  = { mods = {},      key = "right",  repeats = true },
            middle = { mods = {},      key = "delete", repeats = true },
        },
        B = {
            left   = { mods = {"alt"}, key = "left",   repeats = true },
            right  = { mods = {"alt"}, key = "right",  repeats = true },
            middle = { mods = {"alt"}, key = "delete", repeats = true },
        },
        -- Forward + Back held = right Option is held automatically (see the
        -- combo handling in _handleSide). Add per-click combo actions here to
        -- override the default passthrough, e.g.
        --   left = { fn = function() hs.spaces.toggleMissionControl() end },
        FB = {},
    }
end


function obj:_defaultDoubleClickActions()
    return {
        forward = { mods = {}, key = "return" },  -- double-click Forward = Enter
        back    = { mods = {}, key = "escape" },  -- double-click Back = Escape
    }
end


--- Returns the active layer table, or nil if no side button is held.
function obj:_activeLayer()
    if self._down.forward and self._down.back then
        return self.layers.FB
    elseif self._down.forward then
        return self.layers.F
    elseif self._down.back then
        return self.layers.B
    end
    return nil
end


--- Maps a mouse event to a logical button name, or nil to pass it through.
function obj:_classify(etype, event)
    if etype == TYPES.leftMouseDown or etype == TYPES.leftMouseUp then
        return "left"
    elseif etype == TYPES.rightMouseDown or etype == TYPES.rightMouseUp then
        return "right"
    elseif etype == TYPES.otherMouseDown or etype == TYPES.otherMouseUp then
        local n = event:getProperty(PROPS.mouseEventButtonNumber)
        if self.logButtons and etype == TYPES.otherMouseDown then
            self.log.f("otherMouseDown button=%d", n)
        end
        if n == MIDDLE_BUTTON then
            return "middle"
        elseif n == self.forwardButton then
            return "forward"
        elseif n == self.backButton then
            return "back"
        end
    end
    return nil
end


function obj:_fire(action)
    if action.fn then
        action.fn()
    else
        hs.eventtap.event.newKeyEvent(action.mods or {}, action.key, true):post()
        hs.eventtap.event.newKeyEvent(action.mods or {}, action.key, false):post()
    end
end


function obj:_startRepeat(logical, action)
    self:_stopRepeat(logical)
    if not action.repeats then return end
    if not (self.repeatInterval and self.repeatInterval > 0) then return end
    self._repeat[logical] = hs.timer.doAfter(self.repeatDelay or 0.4, function()
        self._repeat[logical] = hs.timer.doEvery(self.repeatInterval, function()
            self:_fire(action)
        end)
    end)
    if self.maxRepeatSeconds and self.maxRepeatSeconds > 0 then
        self._safety[logical] = hs.timer.doAfter(self.maxRepeatSeconds, function()
            self.log.w("max repeat reached; stopping " .. logical)
            self:_stopRepeat(logical)
        end)
    end
end


function obj:_stopRepeat(logical)
    if self._repeat[logical] then
        self._repeat[logical]:stop()
        self._repeat[logical] = nil
    end
    if self._safety[logical] then
        self._safety[logical]:stop()
        self._safety[logical] = nil
    end
end


function obj:_armHoldSafety()
    self:_disarmHoldSafety()
    if self.maxHoldSeconds and self.maxHoldSeconds > 0 then
        self._holdSafety = hs.timer.doAfter(self.maxHoldSeconds, function()
            self._holdSafety = nil
            if self._optionDown then
                self.log.w("max hold reached; force-releasing right Option")
                self:_releaseRightOption()
            end
        end)
    end
end


function obj:_disarmHoldSafety()
    if self._holdSafety then
        self._holdSafety:stop()
        self._holdSafety = nil
    end
end


function obj:_pressRightOption()
    if self._optionDown then return end
    self._optionDown = true
    local e = hs.eventtap.event.newKeyEvent({}, RIGHT_OPTION_KEYCODE, true)
    e:rawFlags(RIGHT_OPTION_FLAGS)
    e:post()
    self:_armHoldSafety()
    self.log.i("right Option DOWN (forward+back)")
end


function obj:_releaseRightOption()
    self:_disarmHoldSafety()
    if not self._optionDown then return end
    self._optionDown = false
    local e = hs.eventtap.event.newKeyEvent({}, RIGHT_OPTION_KEYCODE, false)
    e:rawFlags(0x0)
    e:post()
    self.log.i("right Option UP")
end


function obj:_cancelReplay(logical)
    if self._replayTimer[logical] then
        self._replayTimer[logical]:stop()
        self._replayTimer[logical] = nil
    end
end


--- Posts a real back/forward nav click for a lone (single) side-button press,
--- tagged so the tap passes it straight through instead of reprocessing it.
function obj:_replayNav(logical)
    local n = (logical == "forward") and self.forwardButton or self.backButton
    local loc = hs.mouse.absolutePosition()
    for _, isDown in ipairs({ true, false }) do
        local t = isDown and TYPES.otherMouseDown or TYPES.otherMouseUp
        local e = hs.eventtap.event.newMouseEvent(t, loc)
        e:setProperty(PROPS.mouseEventButtonNumber, n)
        e:setProperty(PROPS.eventSourceUserData, SELF_TAG)
        e:post()
    end
    self.log.df("replayed %s nav (button=%d)", logical, n)
end


--- Handles a side button (forward / back): single click -> replayed nav,
--- double click -> key action, hold-and-click -> modifier layer.
function obj:_handleSide(logical, isDown)
    local other = (logical == "forward") and "back" or "forward"

    if isDown then
        -- Second press inside the double-click window: fire the key action and
        -- drop the nav (the matching up is eaten via _navConsumed).
        if self._pending[logical] then
            self:_cancelReplay(logical)
            self._pending[logical] = false
            self._navConsumed[logical] = true
            self._down[logical] = true
            local action = self.doubleClickActions and self.doubleClickActions[logical]
            if action then self:_fire(action) end
            return true
        end

        self._down[logical] = true
        if self._down[other] then
            -- Both held = a combo, so neither side button replays a nav.
            self._used[logical] = true
            self._used[other] = true
        else
            self._used[logical] = false
        end
        if self._down.forward and self._down.back and not self._optionDown then
            self:_pressRightOption()
        end
        return true
    end

    -- Up.
    self._down[logical] = false
    if not (self._down.forward and self._down.back) and self._optionDown then
        self:_releaseRightOption()
    end

    if self._navConsumed[logical] then
        self._navConsumed[logical] = false
        return true  -- the up of a consumed double-click press
    end
    if self._used[logical] then
        return true  -- was a modifier / combo press: no nav, no double-click
    end

    -- A plain click: wait briefly for a second one; if none comes, replay it as
    -- the default back/forward navigation.
    self._pending[logical] = true
    self:_cancelReplay(logical)
    self._replayTimer[logical] = hs.timer.doAfter(self.doubleClickInterval, function()
        self._replayTimer[logical] = nil
        if self._pending[logical] then
            self._pending[logical] = false
            self:_replayNav(logical)
        end
    end)
    return true
end


function obj:_handle(event)
    -- Ignore the nav clicks we replayed ourselves.
    if event:getProperty(PROPS.eventSourceUserData) == SELF_TAG then
        return false
    end
    local etype = event:getType()
    local logical = self:_classify(etype, event)
    if not logical then
        return false
    end
    local isDown = DOWN[etype] == true

    if logical == "forward" or logical == "back" then
        return self:_handleSide(logical, isDown)
    end

    -- Action buttons: left / right / middle.
    if isDown then
        local layer = self:_activeLayer()
        if not layer then
            self._swallowed[logical] = nil
            return false  -- no side button held: behave normally
        end
        -- A click while a side button is held marks it "used" -- so it won't
        -- replay a nav or fire its double-click action on release.
        if self._down.forward then self._used.forward = true end
        if self._down.back then self._used.back = true end
        local action = layer[logical]
        if not action then
            -- Unbound in this layer (e.g. the FB combo): pass through so the
            -- click behaves normally while right Option is held.
            self._swallowed[logical] = nil
            return false
        end
        self._swallowed[logical] = true
        self:_fire(action)
        self:_startRepeat(logical, action)
        return true
    else
        if self._swallowed[logical] then
            self._swallowed[logical] = nil
            self:_stopRepeat(logical)
            return true
        end
        return false
    end
end


--- MouseLayers:start()
--- Method
--- Starts the global mouse event tap.
function obj:start()
    self:stop()
    self.layers = self.layers or self:_defaultLayers()
    self.doubleClickActions = self.doubleClickActions or self:_defaultDoubleClickActions()
    self._tap = hs.eventtap.new({
        TYPES.leftMouseDown,  TYPES.leftMouseUp,
        TYPES.rightMouseDown, TYPES.rightMouseUp,
        TYPES.otherMouseDown, TYPES.otherMouseUp,
    }, function(e) return self:_handle(e) end)
    self._tap:start()
    self.log.i(string.format(
        "started (back=%d, forward=%d; single-click=nav, double-click=key)",
        self.backButton, self.forwardButton
    ))
    return self
end


--- MouseLayers:stop()
--- Method
--- Stops the event tap and cancels any in-progress timers / held Option.
function obj:stop()
    if self._tap then
        self._tap:stop()
        self._tap = nil
    end
    for _, logical in ipairs({ "left", "right", "middle" }) do
        self:_stopRepeat(logical)
    end
    for _, logical in ipairs({ "forward", "back" }) do
        self:_cancelReplay(logical)
    end
    self:_releaseRightOption()
    self._down = { forward = false, back = false }
    self._used = { forward = false, back = false }
    self._pending = { forward = false, back = false }
    self._navConsumed = { forward = false, back = false }
    self._swallowed = {}
    return self
end


return obj
