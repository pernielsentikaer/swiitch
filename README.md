# Swiitch

A native SwiftUI ⌘+Tab replacement for macOS. Lets you switch between every **window**, not just every app — with live thumbnails, theming, and a customisable hotkey.

<!-- TODO: add a screenshot or short screen-capture GIF here -->

## Features

- **All windows, not just apps.** The default ⌘+Tab shows every window directly. Optional Apps first mode groups by app; ↓ or `` ` `` drills into the selected app's windows.
- **Optional second hotkey** that opens the picker directly in the frontmost app's window list (default ⌥+Tab).
- **Recently used windows first.** Switching between two windows of the same app updates their order too. History follows window focus, including mouse clicks; pinned apps keep priority and tiles stay in place while you choose.
- **Live window thumbnails** via ScreenCaptureKit, with a `CGWindowList` fallback for windows on other Spaces / minimised. Cached images appear immediately while older captures refresh; a failed refresh keeps the last usable image. Periodic refresh follows visible, search-matching tiles and the selected target; scrolling reuses cached previews and refreshes stale ones without discarding hidden previews.
- **Clear preview status.** Loading, unavailable capture, and missing Screen Recording permission have distinct placeholders. Capture requests time out and retry with backoff; permission changes clear stale images and resume loading when access returns. Windows remain switchable even when no preview is available.
- **Type to filter.** Search by app name and window title in every mode, including an app's window grid. Combine words in any order—`dia calendar` finds a Calendar window in Dia. Matching ignores case and accents, keeps recent-window order, and requires all words to match the same app/window pair. Going back from a window search restores the previous app search.
- **Mouse and keyboard parity.** Hover to select, click to commit, arrows / Tab to navigate, ⌃⌘W to close, ⌃⌘H to hide.
- **Optional peek** — hover (or keyboard-navigate) for a beat to bring that window forward while keeping the picker open; Esc restores the exact window you started from, or its app if that window is no longer available.
- **Per-monitor + per-Space filtering** to match the screen you actually mean.
- **Independent minimized-window inclusion.** Include minimized windows even with other Spaces hidden, or leave them out. The screen filter still applies; unavailable Accessibility metadata is not guessed.
- **English and Danish.** Follows macOS's app language, including settings, menus, permission descriptions, and accessibility feedback.
- **Themeable.** Custom accent color, panel material (translucent / frosted / solid), corner radius, thumbnail size, app-icon overlay position, plus one-click presets including Classic, Minimal, Raycast, Frosted, and Spotlight.
- **App pinning and exclusions.** Right-click any app cell to pin it or hide it from Swiitch; excluded apps can be managed in Preferences.
- **Adaptive window grids.** Wrap past a configurable screen width, optionally shrink tiles to fit every window, and move by rows with ↑ / ↓.
- **Live layout preview.** Preferences uses the real cells and grid-sizing rules to demonstrate maximum width, Automatic / Fill Screen, and appearance with adjustable sample counts. No real windows or capture permission are needed for the preview.
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
| ⌘ Tab | Open switcher / next window (or app in Apps first) |
| ⌘ ⇧ Tab | Previous window or app |
| ⌘ ⇧ (no Tab) | Previous, configurable in Switcher → Navigation |
| ↓ or `` ` `` | Drill into selected app's windows; ↓ then moves one grid row |
| ↑ | Move up one grid row; back to apps from the first row |
| ← / → | Same as ⌘+Tab / ⌘+⇧+Tab |
| `letters / digits / spaces` | Filter list |
| ⌫ | Backspace filter |
| ⌃ ⌘ W | Close highlighted window |
| ⌃ ⌘ H | Hide highlighted app |
| Esc | Cancel |
| Release ⌘ | Commit |
| ⌥ Tab | (Optional) Open picker in frontmost app's windows |

Both hotkeys are user-recordable in Preferences → General → Hotkeys.

Recording suspends ordinary switching and catches reserved chords before macOS handles them. Escape, switching away from Swiitch, or leaving General ends recording. Conflicts with the other shortcut—including its Shift-reverse chord—are rejected without replacing the saved binding.

Keep holding the switcher shortcut while typing to search, including H and W. With the default ⌘Tab binding, add Control for Close/Hide. If a custom opening shortcut already requires both Control and Command, H/W remain search text instead of triggering those actions.

## Preferences

Four sidebar sections in Preferences (⌘, from the menu bar):

- **General** — Permission recovery, actual Launch at Login status and approval/error guidance, menu-bar / Dock icon visibility, shortcut recorders, automatic update checks, and reset-to-defaults.
- **Switcher** — Display mode (Apps first / All windows), screen scope, excluded apps, show-delay, Automatic / Fill Screen layout, peek, navigation, and optional thumbnail window controls.
- **Appearance** — Theme presets, system appearance (Light / Dark / System), accent color, panel material + corner radius, thumbnail size, app-icon overlay position.
- **About** — Version, Check for Updates, and Review Diagnostics. The report is shown before copying and contains only versions, permission states, counts, timings, and aggregate filtering reasons—not titles, URLs, screenshots, paths, or an app list.

Thumbnail diagnostics include lifetime cache hits, misses, and capacity evictions. Each
unique window lookup counts once; a hit may still refresh an old image. Evictions count
only removals caused by the memory/entry limit, not window cleanup or permission changes.

Welcome is a first-run flow. General contains ongoing permission recovery; routine updates do not reset onboarding. Automatic checks follow Sparkle's saved setting; development builds start the updater only for a manual check.

Window discovery runs in a bounded background worker and reuses a recent snapshot for quick opening. Window IDs and their owning processes are checked again before native actions. VoiceOver exposes selected tiles, activation, and named Close/Minimize/Zoom actions without requiring a hover.

Window controls are checked on demand for the selected/hovered window, without idle
capability polling. Controls confirmed unavailable by macOS are dimmed with explanatory
tooltips and omitted from VoiceOver's action menu. Unknown metadata still allows a safe,
revalidated attempt. Failed actions display a short explanation in the switcher's reserved
search-badge area, without moving the tiles or changing the selection. Native Close requests
are never treated as force-close: unsaved-changes prompts remain the target app's responsibility.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, code style, and architecture overview. Issue templates are in `.github/ISSUE_TEMPLATE/`.

## License

[MIT](LICENSE) © 2026 Per Nielsen Tikær
