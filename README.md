# Hammerspoon Config

Personal Hammerspoon configuration for macOS automation.

## Spoons

### AudioSwitcher

Automatically switches audio input and output devices based on priority. When devices are connected or disconnected, the highest-priority available device is selected.

### PrimaryDisplay

Manages primary display and window placement based on whether a USB "presence" device — by default the ZSA keyboard — is connected. The keyboard's presence indicates which laptop the shared Dell monitor is actively displaying: when it's plugged into this Mac, the Dell is set as primary; when it's unplugged (taken to the other laptop), the built-in screen becomes primary and all windows are moved back to it. The match device is configurable via `spoon.PrimaryDisplay.targetUSBSubstring` (default `"zsa"`, which matches any ZSA keyboard model by vendor name).

### VolumeDuck

Push-to-duck: hold **Control + Option** (and nothing else) and the system output volume drops to 10%, so every sound source gets quieter at once; release either key and the previous volume comes back. A volume already at or below the duck level is left alone.

Ctrl+Option is also a shortcut prefix, so ducking waits until the combo has been held alone for `holdDelay` seconds (default `0.15`) — a quick Ctrl+Option+<key> doesn't dip the sound. Pressing any other key while ducked restores the volume at once, and the combo stays inert until both modifiers are released.

macOS has no per-app volume, so this ducks the default output device. Outputs without a software volume control (most HDMI / DisplayPort) are skipped. The volume is restored on the device that was ducked even if the default output switches mid-hold, and a pre-duck volume left behind by a reload or crash is restored on the next start.

Knobs in `init.lua`: `duckVolume` (default `10`), `holdDelay` (default `0.15`), `pollInterval` (default `0.5`, the fallback re-check of the real modifier state while ducked).

### RaiseAllWindows

When a configured app becomes active (e.g., via Dock click or Cmd+Tab), raises all of its visible windows above other apps' windows. Restores the older macOS behavior where activating an app brought all its windows to the front, not just the most recently focused one. Defaults to Ghostty; configure `spoon.RaiseAllWindows.appNames` in `init.lua` to change the list (use `{}` for all apps).

Uses AppKit's `NSApplicationActivateAllWindows` option for a single atomic OS-level call — no per-window cascade or AX delay. A per-window AXRaise fallback is available via `spoon.RaiseAllWindows.useFallback = true` for apps the AppKit call doesn't fully cover.

Plays nicely with [AutoRaise](https://github.com/sbmpost/AutoRaise) via two complementary checks:

- `spoon.RaiseAllWindows.requireUserInput = true` (default): only raise on activation when a click or modified keypress (Cmd+Tab, the Alt-prefixed launcher hotkeys, etc.) happened within `userInputWindow` seconds (default 0.25). AutoRaise hovers are pure mouse motion, so they don't qualify and get skipped.
- `spoon.RaiseAllWindows.raiseOnClick = true` (default): after AutoRaise has focused an app, clicking a window of that already-active app doesn't fire a new activation event. The spoon hooks left-clicks too: a short delay (`postClickDelay`, default 0.08 s) after the click, if the clicked window belongs to a configured app whose siblings are still behind other apps, it raises them as well.

Set either flag to `false` to disable that half of the behavior.

The click tap watches left- and right-clicks only. Middle and side buttons pass through untouched, because the tap's callback runs synchronously and does a full window-geometry sweep — enough to add visible input lag to apps that drive interaction from the middle button (Blender orbits on middle-drag).

### MiddleClickRightOption

> Currently disabled in `init.lua` (superseded by **MouseLayers** below); re-enable by uncommenting its `:start()` line.

Turns a **fast double middle-click** anywhere on screen into a held **right Option (⌥)** key: Option is pressed on the second click and released when that middle button is let go (push-to-talk style). A quick double-click gives a quick Option tap; a double-click-and-hold holds Option until you release. The simulated key uses the right-Option keycode and right-side device flag, so apps that distinguish left vs right Option see the right one.

Two knobs in `init.lua`:

- `spoon.MiddleClickRightOption.doubleClickInterval` (default `0.25`): max seconds between the two middle clicks to count as a fast double-click. Tune to your click speed.
- `spoon.MiddleClickRightOption.suppressMiddleClick` (default `true`): when `true`, every middle press is briefly held back so the gesture sends no real middle click (lone middle clicks are replayed after the delay, and a held middle button still autoscrolls). When `false`, ordinary middle clicks fire instantly and only the fast second press is swapped — snappier, but the first middle click of the gesture isn't suppressed.

A stuck-modifier safety net (`maxHoldSeconds`, default `30`, `0` to disable) force-releases Option if the releasing middle-up never arrives.

### MouseLayers

> Currently disabled in `init.lua` (not in active use); re-enable by uncommenting its block.

Gives the mouse's **side buttons** (normally web back/forward) three roles each, without losing their everyday navigation:

- **Single click** → the normal back/forward navigation (replayed after `doubleClickInterval`, so there's a small, deliberate delay).
- **Fast double-click** → a key: **Forward = Enter**, **Back = Escape**.
- **Hold + click a main button** → the side button becomes a modifier layer:

| Held | Left click | Right click | Middle click |
| --- | --- | --- | --- |
| **Forward** | ← | → | Backspace |
| **Back** | ⌥← | ⌥→ | ⌥Backspace |
| **Forward + Back** | _(⌥ held)_ | _(⌥ held)_ | _(⌥ held)_ |

**Forward + Back together** holds **right Option (⌥)** down for as long as both buttons are held (push-to-talk style, same as the old MiddleClickRightOption), releasing it when you let go of either; clicks during the combo pass straight through.

Layer keys auto-repeat: a single click fires once; click-and-hold repeats (after `repeatDelay`, every `repeatInterval`) until release — so holding left under the forward layer walks the cursor.

Knobs in `init.lua`:

- `backButton` / `forwardButton` (defaults `3` / `4`): CGEvent button numbers of your side buttons. They vary by mouse — set `logButtons = true`, reload, click each side button, and read the number from the Hammerspoon console.
- `doubleClickInterval` (default `0.25`): how long a single click is held back while watching for a fast second click (also the delay before a lone click navigates).
- `repeatDelay` (default `0.4`) / `repeatInterval` (default `0.05`): layer-key auto-repeat timing (`repeatInterval = 0` disables repeat).
- `maxRepeatSeconds` (default `10`) / `maxHoldSeconds` (default `30`): safety caps that stop a stuck repeat / release a stuck Option if a button-up is missed.

The full mapping lives in `spoon.MouseLayers.layers` (a plain table; `layers.FB` is the Forward + Back combo). Double-click actions live in `spoon.MouseLayers.doubleClickActions`. Each action is either a keystroke (`{ mods = {"alt"}, key = "left" }`) or a function (`{ fn = function() ... end }`).

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
| Hold Ctrl+Alt | Duck output volume to 10% (VolumeDuck) |
| Alt+V | Open ClipboardAI |
| Alt+C | Copy selection + open ClipboardAI |
| Alt+1 / Alt+B | Chromium (disabled) |
| Alt+2 | Google Chrome (disabled) |
| Alt+T | Telegram (disabled) |
| Alt+G | Ghostty (disabled) |
| Alt+Z | Zed (disabled) |
| Alt+A | Type ä |
| Alt+Shift+A | Type Ä |
| Alt+O | Type ö |
| Alt+Shift+O | Type Ö |
