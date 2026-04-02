-------------------------------------------------------------------------------
-- ClipboardAI.spoon
--
-- AI-powered clipboard processing via modal overlays.
-- Translate, format, and chain operations on clipboard text using Claude CLI.
--
-- Default hotkey: Cmd+Option+V
--
-- Prompts are stored in the prompts/ directory inside this Spoon.
-------------------------------------------------------------------------------

local obj = {}
obj.__index = obj

obj.name = "ClipboardAI"
obj.version = "2.0"

obj.log = hs.logger.new("ClipboardAI", "info")

--- ClipboardAI.hotkey
--- Variable
--- Table with modifiers and key for the trigger hotkey.
obj.hotkey = { mods = {"alt"}, key = "V" }

--- ClipboardAI.claudePath
--- Variable
--- Path to the claude CLI binary.
obj.claudePath = "/opt/homebrew/bin/claude"

--- ClipboardAI.maxLineWidth
--- Variable
--- Maximum character width for text in overlays before word-wrapping.
obj.maxLineWidth = 120

--- ClipboardAI.maxPreviewLines
--- Variable
--- Maximum number of lines shown for text preview in overlays.
obj.maxPreviewLines = 20

--- ClipboardAI.actions
--- Variable
--- Ordered list of actions. Each entry is a table with:
---   key     (string)   - key to press (e.g. "T", "1")
---   label   (string)   - display text in the overlay
---   fn      (function) - called when the action is selected (for leaf actions)
---   submenu (table)    - list of sub-actions (same format), mutually exclusive with fn
obj.actions = {}

obj._alertStyle = { textSize = 18, radius = 12, atScreenEdge = 0 }

obj._modal = nil
obj._subModal = nil
obj._alertId = nil
obj._spoonPath = nil
obj._task = nil
obj._originalClipboard = nil
obj._chosenAction = nil
obj._taskResult = nil
obj._statusLabel = nil
obj._history = {}
obj._copyHotkey = nil


--- Word-wraps and truncates text to fit on screen.
function obj:_preview(text)
    local wrapped = self:_wrap(text)
    local lines = {}
    local count = 0
    for line in (wrapped .. "\n"):gmatch("(.-)\n") do
        count = count + 1
        if count > self.maxPreviewLines then
            table.insert(lines, "... [O] to view full text")
            break
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end


--- Word-wraps text to maxLineWidth, breaking on spaces.
function obj:_wrap(text)
    local max = self.maxLineWidth
    local result = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if #line <= max then
            table.insert(result, line)
        else
            local current = ""
            for word in line:gmatch("%S+") do
                if current == "" then
                    current = word
                elseif #current + 1 + #word <= max then
                    current = current .. " " .. word
                else
                    table.insert(result, current)
                    current = word
                end
            end
            if current ~= "" then
                table.insert(result, current)
            end
        end
    end
    return table.concat(result, "\n")
end


--- Returns the path to this Spoon's directory.
function obj:_getSpoonPath()
    if not self._spoonPath then
        self._spoonPath = hs.spoons.scriptPath()
    end
    return self._spoonPath
end


--- Reads a prompt file from the prompts/ directory.
function obj:_readPrompt(filename)
    local path = self:_getSpoonPath() .. "prompts/" .. filename
    local f = io.open(path, "r")
    if not f then
        self.log.e("Prompt file not found: " .. path)
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end


--- Cancels an in-progress task and restores the clipboard.
function obj:_cancelTask()
    self._chosenAction = nil
    self._taskResult = nil
    if self._task then
        self._task:terminate()
        self._task = nil
    end
    if self._subModal then
        self._subModal:exit()
        self._subModal:delete()
        self._subModal = nil
    end
    if self._originalClipboard then
        hs.pasteboard.setContents(self._originalClipboard)
        self._originalClipboard = nil
    end
    self._history = {}
    hs.alert.show((self._statusLabel or "Task") .. " cancelled", 1)
    self._statusLabel = nil
end


--- Executes the chosen action with the translation result.
function obj:_executeAction(action, result, originalClipboard)
    if action == "copy" then
        hs.pasteboard.setContents(result)
        self._originalClipboard = nil
        hs.alert.show("Copied to clipboard", 2)
    elseif action == "paste" then
        hs.pasteboard.setContents(result)
        hs.eventtap.keyStroke({"cmd"}, "v")
        hs.timer.doAfter(0.2, function()
            hs.pasteboard.setContents(originalClipboard)
            obj._originalClipboard = nil
        end)
        hs.alert.show("Pasted", 2)
    end
end


--- Called when either user choice or task result arrives.
--- If both are ready, executes. Otherwise waits for the other.
function obj:_tryFinish(clipboard)
    if not self._chosenAction or not self._taskResult then
        return
    end

    if self._subModal then
        self._subModal:exit()
        self._subModal:delete()
        self._subModal = nil
    end

    local result = self._taskResult
    local action = self._chosenAction
    self._taskResult = nil
    self._chosenAction = nil
    self._statusLabel = nil

    self:_executeAction(action, result, clipboard)
end


--- Shows the result modal with C/V/O/M/U options.
--- result: the processed text
--- inputClipboard: what was in clipboard before this processing step
--- label: status label for display
function obj:_showResultModal(result, inputClipboard, label)
    if self._subModal then
        self._subModal:exit()
        self._subModal:delete()
    end

    self._taskResult = result
    self._chosenAction = nil
    self._statusLabel = label

    local hasHistory = #self._history > 0
    local actionLines = "[C] Copy\n[V] Paste\n[O] Open\n[M] Modify"
    if hasHistory then
        actionLines = actionLines .. "\n[U] Undo"
    end

    local choice = hs.hotkey.modal.new()
    self._subModal = choice

    function choice:entered()
        obj._alertId = hs.alert.show(
            label .. " ready\n\n" .. obj:_preview(result) .. "\n\n" .. actionLines .. "\n\n[Esc] Cancel",
            obj._alertStyle,
            "infinite"
        )
    end

    function choice:exited()
        if obj._alertId then
            hs.alert.closeSpecific(obj._alertId)
            obj._alertId = nil
        end
    end

    choice:bind({}, "C", function()
        choice:exit()
        obj._history = {}
        obj:_executeAction("copy", result, obj._originalClipboard)
    end)

    choice:bind({}, "V", function()
        choice:exit()
        obj._history = {}
        obj:_executeAction("paste", result, obj._originalClipboard)
    end)

    choice:bind({}, "O", function()
        choice:exit()
        local tmpPath = os.tmpname() .. ".txt"
        local f = io.open(tmpPath, "w")
        if f then
            f:write(result)
            f:close()
            hs.task.new("/usr/bin/open", nil, { "-a", "TextEdit", tmpPath }):start()
        end
        obj._taskResult = nil
        obj._originalClipboard = nil
        obj._statusLabel = nil
        obj._history = {}
    end)

    choice:bind({}, "M", function()
        choice:exit()
        table.insert(obj._history, inputClipboard)
        hs.pasteboard.setContents(result)
        obj._taskResult = nil
        -- Escape goes back to this result modal
        obj:_showSubmenu(obj.actions, "Modify result", function()
            table.remove(obj._history)
            hs.pasteboard.setContents(inputClipboard)
            obj:_showResultModal(result, inputClipboard, label)
        end)
    end)

    if hasHistory then
        choice:bind({}, "U", function()
            choice:exit()
            local prev = table.remove(obj._history)
            hs.pasteboard.setContents(prev)
            obj._taskResult = nil
            if obj._task then
                obj._task:terminate()
                obj._task = nil
            end
            hs.alert.show("Undone", 1)
            obj:_showSubmenu(obj.actions, "Quick Actions")
        end)
    end

    choice:bind({}, "escape", function()
        obj:_cancelTask()
    end)

    choice:enter()
end


--- Processes clipboard contents using Claude CLI with the given prompt.
--- statusLabel is used in all overlay messages (e.g. "Translating", "Formatting").
function obj:_process(promptFile, statusLabel)
    local label = statusLabel or "Processing"
    self._statusLabel = label

    local prompt = self:_readPrompt(promptFile)
    if not prompt then
        hs.alert.show("Error: prompt file not found", 2)
        return
    end

    local clipboard = hs.pasteboard.getContents()
    if not clipboard or clipboard == "" then
        hs.alert.show("Clipboard is empty", 2)
        return
    end

    -- Preserve original clipboard across chained operations
    if not self._originalClipboard then
        self._originalClipboard = clipboard
    end
    self._chosenAction = nil
    self._taskResult = nil

    if self._task then
        self._task:terminate()
        self._task = nil
    end

    if self._subModal then
        self._subModal:exit()
        self._subModal:delete()
    end

    local hasHistory = #self._history > 0
    local actionLines = "[C] Copy\n[V] Paste\n[O] Open\n[M] Modify"
    if hasHistory then
        actionLines = actionLines .. "\n[U] Undo"
    end

    local choice = hs.hotkey.modal.new()
    self._subModal = choice

    function choice:entered()
        obj._alertId = hs.alert.show(
            label .. "...\n\n" .. actionLines .. "\n\n[Esc] Cancel",
            obj._alertStyle,
            "infinite"
        )
    end

    function choice:exited()
        if obj._alertId then
            hs.alert.closeSpecific(obj._alertId)
            obj._alertId = nil
        end
    end

    choice:bind({}, "C", function()
        obj._chosenAction = "copy"
        if obj._taskResult then
            choice:exit()
        else
            if obj._alertId then hs.alert.closeSpecific(obj._alertId) end
            obj._alertId = hs.alert.show(
                label .. "...\n\nWill copy to clipboard...\n\n[Esc] Cancel",
                obj._alertStyle, "infinite"
            )
        end
        obj:_tryFinish(clipboard)
    end)

    choice:bind({}, "V", function()
        obj._chosenAction = "paste"
        if obj._taskResult then
            choice:exit()
        else
            if obj._alertId then hs.alert.closeSpecific(obj._alertId) end
            obj._alertId = hs.alert.show(
                label .. "...\n\nWill paste & restore...\n\n[Esc] Cancel",
                obj._alertStyle, "infinite"
            )
        end
        obj:_tryFinish(clipboard)
    end)

    choice:bind({}, "escape", function()
        obj:_cancelTask()
    end)

    choice:enter()

    -- Start processing in background
    local fullPrompt = prompt .. "\n\n" .. clipboard

    self._task = hs.task.new(self.claudePath, function(exitCode, stdout, stderr)
        obj._task = nil

        if not obj._subModal then return end

        if exitCode ~= 0 then
            obj.log.e("Claude CLI error: " .. (stderr or "unknown"))
            obj:_cancelTask()
            hs.alert.show(label .. " error", 2)
            return
        end

        local result = (stdout or ""):match("^%s*(.-)%s*$")
        if not result or result == "" then
            obj:_cancelTask()
            hs.alert.show("Empty result", 2)
            return
        end

        -- If user already chose C/V, execute immediately
        if obj._chosenAction then
            obj._taskResult = result
            if obj._subModal then
                obj._subModal:exit()
                obj._subModal:delete()
                obj._subModal = nil
            end
            local action = obj._chosenAction
            obj._chosenAction = nil
            obj._statusLabel = nil
            obj._history = {}
            obj:_executeAction(action, result, obj._originalClipboard)
        else
            -- Show full result modal with all options
            obj:_showResultModal(result, clipboard, label)
        end
    end, { "-p", fullPrompt })

    self._task:start()
end


--- Builds overlay text for a list of actions.
--- preview: optional text to show above the action list.
function obj:_overlayText(actions, title, escLabel, preview)
    local lines = { title or "Quick Actions", "" }
    if preview and preview ~= "" then
        table.insert(lines, self:_preview(preview))
        table.insert(lines, "")
    end
    for _, action in ipairs(actions) do
        table.insert(lines, "[" .. action.key .. "] " .. action.label)
    end
    table.insert(lines, "")
    table.insert(lines, "[Esc] " .. (escLabel or "Cancel"))
    return table.concat(lines, "\n")
end


--- Shows a sub-menu modal.
--- backFn: optional function called on Escape instead of just closing.
function obj:_showSubmenu(submenu, title, backFn)
    if self._subModal then
        self._subModal:exit()
        self._subModal:delete()
    end

    local sub = hs.hotkey.modal.new()
    self._subModal = sub

    local overlayTitle = title or "Quick Actions"
    local escLabel = backFn and "Back" or "Cancel"

    function sub:entered()
        local preview = hs.pasteboard.getContents() or ""
        obj._alertId = hs.alert.show(
            obj:_overlayText(submenu, overlayTitle, escLabel, preview),
            obj._alertStyle,
            "infinite"
        )
    end

    function sub:exited()
        if obj._alertId then
            hs.alert.closeSpecific(obj._alertId)
            obj._alertId = nil
        end
    end

    for _, action in ipairs(submenu) do
        sub:bind({}, action.key, function()
            sub:exit()
            if action.submenu then
                -- Nested submenu: Escape goes back to this menu
                obj:_showSubmenu(action.submenu, action.label, function()
                    obj:_showSubmenu(submenu, title, backFn)
                end)
            elseif action.fn then
                action.fn()
            end
        end)
    end

    sub:bind({}, "escape", function()
        sub:exit()
        if backFn then backFn() end
    end)

    sub:enter()
end


--- ClipboardAI:start()
--- Method
--- Creates the modal and binds the trigger hotkey.
function obj:start()
    self:stop()

    -- Set default actions if none configured
    if #self.actions == 0 then
        self.actions = {
            {
                key = "T", label = "Translate clipboard",
                submenu = {
                    { key = "1", label = "English", fn = function()
                        obj:_process("translate_en.txt", "Translating")
                    end },
                    { key = "2", label = "Finnish", fn = function()
                        obj:_process("translate_fi.txt", "Translating")
                    end },
                    { key = "3", label = "Russian", fn = function()
                        obj:_process("translate_ru.txt", "Translating")
                    end },
                },
            },
            {
                key = "F", label = "Format clipboard",
                submenu = {
                    { key = "1", label = "Fix grammar", fn = function()
                        obj:_process("format_grammar.txt", "Formatting")
                    end },
                    { key = "2", label = "Business tone", fn = function()
                        obj:_process("format_business.txt", "Formatting")
                    end },
                    { key = "3", label = "Polite tone", fn = function()
                        obj:_process("format_polite.txt", "Formatting")
                    end },
                    { key = "4", label = "Playful tone", fn = function()
                        obj:_process("format_playful.txt", "Formatting")
                    end },
                    { key = "5", label = "Biblical style", fn = function()
                        obj:_process("format_biblical.txt", "Formatting")
                    end },
                },
            },
            {
                key = "A", label = "Analyze clipboard",
                submenu = {
                    { key = "1", label = "Brief summary", fn = function()
                        obj:_process("analyze_summary.txt", "Analyzing")
                    end },
                    { key = "2", label = "Explain simply", fn = function()
                        obj:_process("analyze_explain.txt", "Analyzing")
                    end },
                },
            },
        }
    end

    local modal = hs.hotkey.modal.new(self.hotkey.mods, self.hotkey.key)
    self._modal = modal

    function modal:entered()
        local preview = hs.pasteboard.getContents() or ""
        local text = obj:_overlayText(obj.actions, nil, nil, preview)
        -- Insert clipboard actions before [Esc]
        text = text:gsub("\n%[Esc%]",
            "\n[C] Copy  [V] Paste  [O] Open\n\n[Esc]")
        obj._alertId = hs.alert.show(text, obj._alertStyle, "infinite")
    end

    function modal:exited()
        if obj._alertId then
            hs.alert.closeSpecific(obj._alertId)
            obj._alertId = nil
        end
    end

    for _, action in ipairs(self.actions) do
        modal:bind({}, action.key, function()
            modal:exit()
            if action.submenu then
                self:_showSubmenu(action.submenu, action.label)
            elseif action.fn then
                action.fn()
            end
        end)
    end

    -- Clipboard actions on the top-level modal
    modal:bind({}, "C", function()
        modal:exit()
        hs.alert.show("Copied to clipboard", 2)
    end)

    modal:bind({}, "V", function()
        modal:exit()
        hs.eventtap.keyStroke({"cmd"}, "v")
        hs.alert.show("Pasted", 2)
    end)

    modal:bind({}, "O", function()
        modal:exit()
        local content = hs.pasteboard.getContents() or ""
        if content ~= "" then
            local tmpPath = os.tmpname() .. ".txt"
            local f = io.open(tmpPath, "w")
            if f then
                f:write(content)
                f:close()
                hs.task.new("/usr/bin/open", nil, { "-a", "TextEdit", tmpPath }):start()
            end
        end
    end)

    modal:bind({}, "escape", function()
        modal:exit()
    end)

    -- Alt+C: copy selection then open ClipboardAI
    self._copyHotkey = hs.hotkey.bind({"alt"}, "C", function()
        hs.eventtap.keyStroke({"cmd"}, "c")
        hs.timer.doAfter(0.1, function()
            self:show()
        end)
    end)

    self.log.i("ClipboardAI started")
    return self
end


--- ClipboardAI:show()
--- Method
--- Programmatically opens the main modal overlay.
function obj:show()
    if self._modal then
        self._modal:enter()
    end
    return self
end


--- ClipboardAI:stop()
--- Method
--- Removes all modals and cleans up.
function obj:stop()
    self._chosenAction = nil
    self._taskResult = nil
    self._statusLabel = nil
    self._history = {}
    if self._copyHotkey then
        self._copyHotkey:delete()
        self._copyHotkey = nil
    end
    if self._subModal then
        self._subModal:exit()
        self._subModal:delete()
        self._subModal = nil
    end
    if self._modal then
        self._modal:exit()
        self._modal:delete()
        self._modal = nil
    end
    if self._task then
        self._task:terminate()
        self._task = nil
    end
    return self
end

return obj
