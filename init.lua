hs.loadSpoon("FifineDisplay")
spoon.FifineDisplay:start()

-- Window Management
hs.hotkey.bind({"cmd", "shift"}, "2", function()
    local output = hs.execute("/opt/homebrew/bin/ocr")

    -- trim whitespace/newlines
    output = output and output:gsub("^%s*(.-)%s*$", "%1")

    if output ~= "" then
        hs.alert.show(output)
    else
        hs.alert.show("OCR returned nothing")
    end
end)

hs.hotkey.bind({"alt"}, "1", function()
    hs.application.launchOrFocus("Chromium")
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
