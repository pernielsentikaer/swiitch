---
description: "Use when working on SwiftUI views, the switcher panel, preferences UI, welcome screen, or theme system. Covers layout patterns, theming, and panel hosting."
applyTo: "Swiitch/UI/**/*.swift"
---
# SwiftUI UI Guidelines

## Panel Hosting

- `SwitcherPanel` is a `.nonactivatingPanel` — views inside must never assume the app is frontmost
- Keyboard events are captured at the `CGEventTap` level (via `HotkeyManager`), not via SwiftUI `onKeyPress` — add new key handling there, not in view bodies

## Layout

- The switcher grid wraps based on `SwitcherModel.effectiveMaxWidth` (computed from screen width × `maxPanelWidthPercent`); use this value rather than hardcoding widths
- Hover-based selection is guarded by `SwitcherModel.mouseHasMoved`; respect this flag when adding new pointer interactions to avoid snapping selection on panel open

## Theming

- Panel chrome and accent colours come from `Theme/Theme.swift` (`Theme.panelBackground`, the user's accent hex). Semantic system colours are fine in views — `Color.primary` / `.secondary` for text and hairlines, `Color.green` / `.orange` for permission status — but never hard-code brand-like RGB/hex literals in a view; add them to `Theme` (or a preset) instead
- Appearance preferences are read with `@AppStorage(Preferences.Key…)` in the view that needs them, and passed down explicitly to subviews; don't reach into `UserDefaults.standard` directly from a view

## Filter UI

- The filter text badge at the bottom of the switcher is driven by `SwitcherModel.filterText`; keep filter rendering and model mutations in sync through the model, not view-local state

## Preferences

- `PreferencesView` uses a sidebar with General / Switcher / Appearance / About sections. Ongoing permission recovery belongs in General, not repeated onboarding.
- Bind new preference controls directly to `@AppStorage(Preferences.Key.xxx)` using the keys defined in `Preferences/Preferences.swift`
- OS-owned status (login registration, permission grants, and Sparkle settings) must be read from the responsible service, not inferred from a saved intent flag. Keep diagnostics limited to allowlisted aggregate data.
