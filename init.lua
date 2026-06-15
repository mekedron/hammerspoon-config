hs.loadSpoon("FifineDisplay")
spoon.FifineDisplay:start()

hs.loadSpoon("AudioSwitcher")
spoon.AudioSwitcher:start()

hs.loadSpoon("RaiseAllWindows")
spoon.RaiseAllWindows.appNames = {"Ghostty", "Finder", "Zed"}
spoon.RaiseAllWindows:start()

hs.loadSpoon("MiddleClickRightOption")
-- Max seconds between the two middle clicks to count as a fast double-click.
-- Tune this to your click speed (also the delay added to lone middle clicks
-- while suppress is on).
spoon.MiddleClickRightOption.doubleClickInterval = 0.25
-- true  = suppress both clicks; replay a lone middle click after the delay.
-- false = keep the first middle click instant; only swap the fast 2nd press.
spoon.MiddleClickRightOption.suppressMiddleClick = true
-- Temporarily disabled in favor of MouseLayers (side buttons as modifier
-- layers). Re-enable by uncommenting the line below.
-- spoon.MiddleClickRightOption:start()

hs.loadSpoon("MouseLayers")
-- Side-button numbers (vary by mouse; common 5-button convention is back=3,
-- forward=4). With logButtons = true, reload and click each side button to see
-- its number in the Hammerspoon console, then set these and turn logging off.
spoon.MouseLayers.backButton = 3
spoon.MouseLayers.forwardButton = 4
spoon.MouseLayers.logButtons = true
-- A single side-button click passes through as the normal browser back/forward
-- after this delay; a fast second click fires its key (forward=Enter,
-- back=Escape) instead. Raise it if double-clicks aren't being caught.
spoon.MouseLayers.doubleClickInterval = 0.25
-- Key auto-repeat while a side button is held and you click a main button.
spoon.MouseLayers.repeatDelay = 0.4
spoon.MouseLayers.repeatInterval = 0.05
spoon.MouseLayers:start()

-- hs.loadSpoon("ClipboardAI")
-- spoon.ClipboardAI:start()

-- OCR
-- hs.hotkey.bind({"cmd", "shift"}, "2", function()
 --    local output = hs.execute("/opt/homebrew/bin/ocr -l eng+rus")
    -- if output ~= "" then
       --  hs.pasteboard.setContents(output)
    -- end
--end)

-- OCR to clipboard
-- hs.hotkey.bind({"cmd", "shift"}, "1", function()
--     local output = hs.execute("/opt/homebrew/bin/ocr -l eng+rus")
--     if output ~= "" then
--         hs.pasteboard.setContents(output)
--     end
-- end)

hs.hotkey.bind({"alt"}, "1", function()
    hs.application.launchOrFocus("Chromium")
end)

hs.hotkey.bind({"alt"}, "2", function()
    hs.application.launchOrFocus("Google Chrome")
end)

hs.hotkey.bind({"alt"}, "T", function()
    hs.application.launchOrFocus("Telegram")
end)

hs.hotkey.bind({"alt"}, "B", function()
    hs.application.launchOrFocus("Chromium")
end)

hs.hotkey.bind({"alt"}, "G", function()
    hs.application.launchOrFocus("Ghostty")
end)

hs.hotkey.bind({"alt"}, "Z", function()
    hs.application.launchOrFocus("Zed")
end)

-- ä / Ä
hs.hotkey.bind({"alt"}, "a", function()
    hs.eventtap.keyStrokes(" ä")
end)

hs.hotkey.bind({"alt", "shift"}, "a", function()
    hs.eventtap.keyStrokes(" Ä")
end)

-- ö / Ö
hs.hotkey.bind({"alt"}, "o", function()
    hs.eventtap.keyStrokes("ö")
end)

hs.hotkey.bind({"alt", "shift"}, "o", function()
    hs.eventtap.keyStrokes("Ö")
end)
