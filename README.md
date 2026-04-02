# Hammerspoon Config

Personal Hammerspoon configuration for macOS automation.

## Spoons

### AudioSwitcher

Automatically switches audio input and output devices based on priority. When devices are connected or disconnected, the highest-priority available device is selected.

### FifineDisplay

Manages primary display and window placement based on whether the Fifine USB microphone is connected. The microphone presence indicates which laptop the shared Dell monitor is actively displaying.

### ClipboardAI

AI-powered clipboard processing. Triggered by **Cmd+Option+V**, opens a modal overlay to translate or format clipboard text using Claude CLI.

**Translate** — English, Finnish, Russian

**Format** — Fix grammar, Business tone, Polite tone, Playful tone, Biblical style

**Analyze** — Brief summary, Explain simply

After processing, choose to copy, paste, open in TextEdit, or chain another operation with Modify. Undo reverts to the previous step.

Prompts are stored as separate text files and can be easily customized.

## Shortcuts

| Shortcut | Action |
|---|---|
| Cmd+Shift+1 | OCR screen selection + open ClipboardAI |
| Cmd+Shift+2 | OCR screen selection to clipboard |
| Alt+V | Open ClipboardAI |
| Alt+C | Copy selection + open ClipboardAI |
| Alt+1 / Alt+B | Chromium |
| Alt+T | Telegram |
| Alt+G | Ghostty |
| Alt+Z | Zed |
| Alt+A | Type ä |
| Alt+Shift+A | Type Ä |
| Alt+O | Type ö |
| Alt+Shift+O | Type Ö |
