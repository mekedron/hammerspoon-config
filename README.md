# Hammerspoon Config

Personal Hammerspoon configuration for macOS automation.

## Spoons

### AudioSwitcher

Automatically switches audio input and output devices based on priority. When devices are connected or disconnected, the highest-priority available device is selected.

### FifineDisplay

Manages primary display and window placement based on whether the Fifine USB microphone is connected. The microphone presence indicates which laptop the shared Dell monitor is actively displaying.

### RaiseAllWindows

When a configured app becomes active (e.g., via Dock click or Cmd+Tab), raises all of its visible windows above other apps' windows. Restores the older macOS behavior where activating an app brought all its windows to the front, not just the most recently focused one. Defaults to Ghostty; configure `spoon.RaiseAllWindows.appNames` in `init.lua` to change the list (use `{}` for all apps).

Uses AppKit's `NSApplicationActivateAllWindows` option for a single atomic OS-level call — no per-window cascade or AX delay. A per-window AXRaise fallback is available via `spoon.RaiseAllWindows.useFallback = true` for apps the AppKit call doesn't fully cover.

Plays nicely with [AutoRaise](https://github.com/sbmpost/AutoRaise) via two complementary checks:

- `spoon.RaiseAllWindows.requireUserInput = true` (default): only raise on activation when a click or modified keypress (Cmd+Tab, the Alt-prefixed launcher hotkeys, etc.) happened within `userInputWindow` seconds (default 0.25). AutoRaise hovers are pure mouse motion, so they don't qualify and get skipped.
- `spoon.RaiseAllWindows.raiseOnClick = true` (default): after AutoRaise has focused an app, clicking a window of that already-active app doesn't fire a new activation event. The spoon hooks left-clicks too: a short delay (`postClickDelay`, default 0.08 s) after the click, if the clicked window belongs to a configured app whose siblings are still behind other apps, it raises them as well.

Set either flag to `false` to disable that half of the behavior.

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
| Cmd+Shift+1 | OCR screen selection to clipboard |
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
