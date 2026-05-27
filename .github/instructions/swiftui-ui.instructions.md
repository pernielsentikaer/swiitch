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

- All colours come from `Theme/Theme.swift` — never use literal `Color(...)` values in views
- `Theme` is read from `@AppStorage`; inject it via the environment or pass it explicitly, don't reach into `UserDefaults` directly from a view

## Filter UI

- The filter text badge at the bottom of the switcher is driven by `SwitcherModel.filterText`; keep filter rendering and model mutations in sync through the model, not view-local state

## Preferences

- `PreferencesView` is a `TabView` with General / Switcher / Appearance / About tabs — add new settings to the appropriate tab
- Bind new preference controls directly to `@AppStorage(Preferences.Key.xxx)` using the keys defined in `Preferences/Preferences.swift`
