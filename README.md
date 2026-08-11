# Swiitch

A native SwiftUI ⌘+Tab replacement for macOS. Lets you switch between every **window**, not just every app — with live thumbnails, theming, and a customisable hotkey.

<!-- TODO: add a screenshot or short screen-capture GIF here -->

## Features

- **All windows, not just apps.** The default ⌘+Tab cycles apps; ↓ or `` ` `` drills into the selected app's windows.
- **Optional second hotkey** that opens the picker directly in the frontmost app's window list (default ⌥+Tab).
- **Live window thumbnails** via ScreenCaptureKit, with a `CGWindowList` fallback for windows on other Spaces / minimised.
- **Type to filter.** While the picker is open, just start typing — narrows the list by name or window title.
- **Mouse and keyboard parity.** Hover to select, click to commit, arrows / Tab to navigate, ⌘W to close, ⌘H to hide.
- **Optional peek** — hover (or keyboard-navigate) for a beat to bring that window forward while keeping the picker open; Esc restores the app you started from.
- **Per-monitor + per-Space filtering** to match the screen you actually mean.
- **Themeable.** Custom accent color, panel material (translucent / frosted / solid), corner radius, thumbnail size, app-icon overlay position, plus one-click presets (Classic / Minimal / Raycast-style / Frosted / Spotlight-style).
- **App pinning and exclusions.** Right-click any app cell to pin it or hide it from Swiitch; excluded apps can be managed in Preferences.
- **Adaptive window grids.** Wrap past a configurable screen width, optionally shrink tiles to fit every window, and move by rows with ↑ / ↓.
- **Configurable show-delay** so quick ⌘+Tab→release switches without ever showing the panel.
- Lives in the menu bar by default; can be hidden entirely.

## Requirements

- macOS 14 (Sonoma) or newer.
- **Accessibility** permission — mandatory. Used to intercept ⌘+Tab and raise windows across other apps.
- **Screen Recording** permission — optional. Required for window thumbnails.

## Install

Download the latest archive from [GitHub Releases](https://github.com/pernielsentikaer/swiitch/releases/latest).

> **Current release note:** v0.1.4 is an early Apple-silicon-only, ad-hoc-signed build. Control-click the app and choose **Open** on first launch to approve it. Intel support and normal Gatekeeper approval require the next universal, notarized release.

Or build from source — see [CONTRIBUTING.md](CONTRIBUTING.md#development-setup).

## Build from source (TL;DR)

```bash
brew install xcodegen
git clone https://github.com/pernielsentikaer/swiitch.git
cd swiitch
xcodegen generate
open Swiitch.xcodeproj
```

The project builds with ad-hoc signing out of the box. For stable TCC permission grants across rebuilds, follow the [Recommended signing setup](CONTRIBUTING.md#recommended-stable-tcc-across-rebuilds) in CONTRIBUTING.

## Why not the Mac App Store?

Swiitch uses the private `_AXUIElementGetWindow` Accessibility SPI to reliably map AX elements to `CGWindowID`s — the only robust way to disambiguate, say, multiple Chrome windows with identical titles. It can also dynamically load a SkyLight activation fallback when Chromium-family apps ignore the public activation paths. Apple rejects apps that use private SPIs, so Swiitch is distributed outside the Store. Auto-updates ship via [Sparkle](https://sparkle-project.org/).

## Default shortcuts

| Shortcut | Action |
|---|---|
| ⌘ Tab | Open switcher / next app |
| ⌘ ⇧ Tab | Previous app |
| ⌘ ⇧ (no Tab) | Previous, configurable in Switcher → Navigation |
| ↓ or `` ` `` | Drill into selected app's windows; ↓ then moves one grid row |
| ↑ | Move up one grid row; back to apps from the first row |
| ← / → | Same as ⌘+Tab / ⌘+⇧+Tab |
| `letters / digits` | Filter list |
| ⌫ | Backspace filter |
| ⌘ W | Close highlighted window |
| ⌘ H | Hide highlighted app |
| Esc | Cancel |
| Release ⌘ | Commit |
| ⌥ Tab | (Optional) Open picker in frontmost app's windows |

Both hotkeys are user-recordable in Preferences → General → Hotkeys.

## Preferences

Four tabs in ⌘, from the menu bar:

- **General** — Permissions, Launch at login, menu-bar / Dock icon visibility, hotkey recorders, and reset-to-defaults.
- **Switcher** — Display mode (apps vs flat windows), screen scope, excluded apps, show-delay, wrapping / fit-to-screen, peek, navigation, and the window-list toggle.
- **Appearance** — Theme presets, system appearance (Light / Dark / System), accent color, panel material + corner radius, thumbnail size, app-icon overlay position.
- **About** — Version + Welcome window button.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, code style, and architecture overview. Issue templates are in `.github/ISSUE_TEMPLATE/`.

## License

[MIT](LICENSE) © 2026 Per Nielsen Tikær
