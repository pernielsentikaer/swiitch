---
description: "Use when writing or editing Swift source files. Covers Swift 5.10 style, AppKit/SwiftUI interop, concurrency, and project-specific patterns."
applyTo: "**/*.swift"
---
# Swift Guidelines

## Style

- 4-space indentation, no tabs
- `///` doc comments on public types and any non-obvious internal logic
- Trailing commas in multi-line collections
- Keep functions short and single-purpose; extract helpers rather than adding `// MARK: -` blocks inside long functions

## SwiftUI / AppKit Interop

- **AppKit owns all windows**: use `NSPanel` / `NSWindow` subclasses (see `UI/SwitcherPanel.swift`, `UI/PreferencesWindowController.swift`) — never let SwiftUI manage window lifecycle directly
- **SwiftUI owns view bodies**: layout, state bindings, and animations live in SwiftUI views
- Avoid `Settings` scene + `showSettingsWindow:` — use `PreferencesWindowController.shared.show()` instead (sidesteps a SwiftUI logging bug)

## State & Settings

- Prefer `@AppStorage` for all user-facing preferences over a shared `ObservableObject`
  - Reason: `@Published` bindings flowing into `MenuBarExtra(isInserted:)` log "Publishing changes from within view updates is not allowed"
- `SwitcherModel` is the single source of truth for switcher state; route new switcher behaviour through it, not through view-local `@State`

## Concurrency

- `SWIFT_STRICT_CONCURRENCY = minimal` — don't mass-annotate existing code
- New async entry points that touch UI must be `@MainActor`
- `WindowThumbnails` is an actor; call it with `await`, don't add `@MainActor` to it

## Private SPI

- `_AXUIElementGetWindow` in `Windows/AXPrivate.swift` is intentional and load-bearing — do not remove or stub it out
- Any new private API must be guarded with `@available` or `dlsym` fallback and documented inline
