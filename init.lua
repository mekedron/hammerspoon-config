hs.loadSpoon("FifineDisplay")
spoon.FifineDisplay:start()

hs.loadSpoon("AudioSwitcher")
spoon.AudioSwitcher:start()

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
hs.hotkey.bind({"cmd", "shift"}, "1", function()
    local output = hs.execute("/opt/homebrew/bin/ocr -l eng+rus")
    if output ~= "" then
        hs.pasteboard.setContents(output)
    end
end)

hs.hotkey.bind({"alt"}, "1", function()
    hs.application.launchOrFocus("Chromium")
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
