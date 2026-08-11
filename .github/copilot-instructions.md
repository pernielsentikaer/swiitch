# Swiitch — Project Guidelines

Swiitch is a native macOS menubar utility (Swift 5.10, macOS 14+) that lets users switch between apps and windows via a configurable hotkey. It is **not** distributed via the Mac App Store due to private SPI usage.

## Architecture

```
SwiitchApp.swift          @main — MenuBarExtra + routes Preferences/Welcome to custom NSWindow controllers
AppDelegate.swift         App shell, permission gating, UserDefaults observation
Model/SwitcherModel.swift 3-mode ObservableObject state machine (apps / windowsForApp / flatWindows)
Hotkey/HotkeyManager.swift CGEventTap, two configurable shortcuts
Hotkey/FocusTracker.swift  MRU ordering via NSWorkspace activation notifications
Windows/WindowEnumerator   CGWindowList + AX ghost-filter, screen-scope filtering
Windows/WindowFocuser      AX raise + frontmost + activate, close, hide
Windows/WindowThumbnails   ScreenCaptureKit + CGWindowList fallback (actor)
Windows/AXPrivate.swift    _AXUIElementGetWindow private SPI — required for reliable window matching
UI/SwitcherPanel.swift     .nonactivatingPanel host (AppKit)
UI/SwitcherView.swift      SwiftUI grid + filter badge + cells
UI/Preferences*, Welcome*  NSWindow-hosted SwiftUI preference and onboarding views
Theme/                     Theme + ColorHex
Permissions/               AX + Screen Recording polling
Preferences/               UserDefaults keys + side-effect helpers
```

Key constraint: `_AXUIElementGetWindow` SPI in `AXPrivate.swift` is intentional. Do not remove it or replace it without a working substitute — it underpins reliable window-to-CGWindowID mapping.

## Build & Test

```bash
# Generate Xcode project after adding/removing/moving files
xcodegen generate

# Build (CI-style)
xcodebuild -project Swiitch.xcodeproj -scheme Swiitch -configuration Debug test

# Release
Scripts/build_release.sh <version>
```

See `CONTRIBUTING.md` for local signing setup (required for stable TCC across rebuilds).

## Code Style

See `CONTRIBUTING.md` for the full style guide. Critical points agents must follow:

- **4-space indentation**, Swift 5.10
- `///` doc comments on all public types and non-obvious internals
- Prefer `@AppStorage` for user-facing settings — `@Published` bindings into `MenuBarExtra(isInserted:)` trigger SwiftUI publishing warnings
- AppKit for all windowing (`NSPanel`, `NSWindow`); SwiftUI for view bodies only
- `SWIFT_STRICT_CONCURRENCY` is set to `minimal` — annotate new async code with `@MainActor` where appropriate, but do not mass-annotate existing code

## Conventions

- `project.yml` (XcodeGen) is the source of truth for the Xcode project. **Never edit `.xcodeproj` directly.** After touching `project.yml`, run `xcodegen generate`.
- Sparkle handles binary updates; `appcast.xml` at repo root is the feed.
- `build/` is gitignored — release artifacts never land in the repo.
- `Config/Signing.local.xcconfig` is gitignored — contributors create their own from the `.example` template.
