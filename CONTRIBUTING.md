# Contributing to Swiitch

Thanks for your interest in helping out! Swiitch is a small native macOS utility, so contributions of any size are welcome — bug reports, small fixes, new preferences, themes, you name it.

## Development setup

Prerequisites:
- macOS 14 (Sonoma) or newer
- Xcode 15 or newer (Xcode 16+ recommended for macOS 14 SDK with latest SwiftUI conveniences)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

Clone and generate the Xcode project:

```bash
git clone https://github.com/pernielsentikaer/swiitch.git
cd swiitch
xcodegen generate
open Swiitch.xcodeproj
```

By default the project builds with **ad-hoc signing** (`CODE_SIGN_IDENTITY = -`). That's enough to run locally, but every rebuild produces a new code signature, which means macOS TCC (Accessibility / Screen Recording) treats the rebuilt binary as a different app and re-prompts for the grant.

### Recommended: stable TCC across rebuilds

To stop the permission re-prompts, sign with your own Apple Development certificate:

1. In Xcode → Settings → Accounts, add your Apple ID. A free Personal Team is fine.
2. Find your cert SHA1 + team ID:
   ```bash
   security find-identity -v -p codesigning
   security find-certificate -c "Apple Development: your@email" -p \
     | openssl x509 -noout -subject
   ```
   For Personal Teams, your `DEVELOPMENT_TEAM` value is the `OU` field of the cert, not the parenthetical in the CN.
3. Copy the local-config template:
   ```bash
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   ```
4. Fill in `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` in `Config/Signing.local.xcconfig`. That file is gitignored.
5. Re-run `xcodegen generate` if the project is open.

Keep the same bundle identifier, install path, and designated signing requirement across rebuilds to preserve TCC identity. macOS remains authoritative about grants; signing does not guarantee permission persistence after every OS or certificate change. Never reset TCC as a routine update step.

## Regenerating the project after file changes

If you add, remove, or move source files, re-run `xcodegen generate`. Xcode may need to be quit-and-reopened to pick up the new project graph cleanly.

The root `Package.resolved` is the reviewed dependency lock. XcodeGen's post-generation hook copies it into the generated workspace. Build with `-onlyUsePackageVersionsFromResolvedFile`; CI verifies the copy and compiles both Debug tests and universal Release. To update dependencies deliberately, resolve the intended version in Xcode, copy the resulting lock back to the root, review its revision/version changes, and rerun tests. Do not silently regenerate the root lock during normal builds.

## Localization and native validation

User-facing text lives in `Swiitch/Resources/Localizable.xcstrings`; native permission
descriptions live in `InfoPlist.xcstrings`. Keep preference keys, app/window identities,
and diagnostic JSON fields unlocalized. Wrap dynamically assembled labels in
`String(localized:)`; ordinary SwiftUI string literals are extracted by the compiler.
Preserve format placeholders when adding translations.

Run language-specific checks with `-testLanguage en -testRegion US` or
`-testLanguage da -testRegion DK` on the normal `xcodebuild test` command.
`LocalizationTests` checks packaged translations, fallback, placeholders, and renders.

The opt-in `NativeWindowScopeTests` only operates on its own disposable AppKit windows.
Run with `TEST_RUNNER_SWIITCH_NATIVE_WINDOW_TESTS=1` and existing Accessibility permission.
The native thumbnail test also requires existing Screen Recording permission. Without
the opt-in or required permission a test explicitly skips; it never prompts or resets TCC.
The accessibility-node test may require a live AX client during its inspection pause
(`TEST_RUNNER_SWIITCH_AX_INSPECTION_SECONDS=30`). These are not substitutes for full
VoiceOver, multi-display, Spaces, sleep/wake, or physical-keyboard testing.

## Regenerating the app icon

```bash
swift Scripts/generate_icon.swift
```

The script writes PNGs into `Swiitch/Resources/Assets.xcassets/AppIcon.appiconset/` and updates `Contents.json`.

## Code style

- Swift 5.10, indented with 4 spaces.
- Doc comments (`///`) on public types and non-obvious internals.
- Prefer plain `@AppStorage` for user-facing settings over a shared `ObservableObject` — there's a SwiftUI gotcha where `@Published` bindings into `MenuBarExtra(isInserted:)` log "Publishing changes from within view updates is not allowed."
- AppKit interop for windowing (`NSPanel`, `NSWindow`), SwiftUI for view bodies.
- `@_silgen_name("_AXUIElementGetWindow")` is used in `Swiitch/Windows/AXPrivate.swift` to map AX elements to `CGWindowID`. The same file dynamically resolves a SkyLight fallback when normal app activation fails. These are private SPIs and mean **Swiitch cannot be distributed via the Mac App Store**. Keep the SkyLight path optional and gated so a missing symbol never prevents launch.

## Pull requests

- Keep PRs focused. One feature or fix per PR is ideal.
- Run the test suite before opening:
  ```bash
  xcodegen generate
  xcodebuild -project Swiitch.xcodeproj -scheme Swiitch -configuration Debug test
  ```
- For UI changes, attach a screenshot or short screen-capture GIF.
- For behavior changes that touch the switcher state machine, mention what you tested manually.

## Architecture quick-tour

```
Swiitch/
  SwiitchApp.swift                @main, MenuBarExtra; AppKit owns windows
  AppDelegate.swift               app shell, permission gating, defaults observation
  Model/SwitcherModel.swift       apps / windowsForApp / flatWindows / currentAppWindows
  Hotkey/HotkeyManager.swift      CGEventTap, two configurable shortcuts
  Hotkey/FocusTracker.swift       per-app and per-window MRU via Workspace + AX notifications
  Hotkey/Shortcut.swift           keycode + flags <-> human label helpers
  Windows/WindowEnumerator.swift  CGWindowList + AX ghost-filter, screen-scope filtering
  Windows/WindowFocuser.swift     AX raise + frontmost + activate, close, hide
  Windows/WindowThumbnails.swift  ScreenCaptureKit + CGWindowList fallback (actor)
  Windows/AXPrivate.swift         _AXUIElementGetWindow + optional SkyLight SPIs
  UI/SwitcherPanel.swift          .nonactivatingPanel host
  UI/SwitcherView.swift           SwiftUI grid + filter badge + cells
  UI/WelcomeView.swift / WelcomeWindowController.swift
  UI/PreferencesView.swift        sidebar (General / Switcher / Appearance / About)
  UI/ShortcutRecorder.swift       keyDown capture + binding
  Theme/Theme.swift, ColorHex.swift
  Permissions/PermissionsMonitor.swift  AX + Screen Recording polling
  Preferences/Preferences.swift   UserDefaults keys + side-effect helpers
SwiitchTests/
  SwitcherModelTests.swift        filtering, selection, focus, grid, and action regressions
```

## Where to start

Good first PR candidates:
- More theme presets (Appearance → Preset)
- Additional languages in `Resources/Localizable.xcstrings` and `InfoPlist.xcstrings`; English and Danish are included
- VoiceOver interaction coverage across supported macOS versions
- More unit tests for `SwitcherModel` advance / pinning logic
- A `swift-format` config + `make format` script

## Releases (maintainer notes)

Swiitch ships binary updates via [Sparkle](https://sparkle-project.org). The flow:

1. **First-time setup** (done once on the maintainer's machine):
   - After Xcode resolves Sparkle's SPM artifacts, generate an EdDSA keypair:
     ```bash
     ~/Library/Developer/Xcode/DerivedData/Swiitch-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
     ```
   - The private key lands in your macOS Keychain (back it up — losing it locks out future updates from existing installs).
   - The public key is printed to stdout. It's already pasted into `Swiitch/Resources/Info.plist` under `SUPublicEDKey`.
   - Install a **Developer ID Application** certificate from the Apple Developer portal. A paid Apple Developer account is required for a Gatekeeper-compatible release. Point `Config/Signing.local.xcconfig` at that identity and its team ID.
   - Store App Store Connect notarization credentials in the Keychain, then export the profile name for the release script:
     ```bash
     xcrun notarytool store-credentials "swiitch-notary" \
       --apple-id "you@example.com" \
       --team-id "YOUR_TEAM_ID" \
       --password "APP_SPECIFIC_PASSWORD"
     export SWIITCH_NOTARY_PROFILE="swiitch-notary"
     ```

2. **For each release**:
   ```bash
   Scripts/build_release.sh 0.2.0 48
   ```
   This:
   - Refuses a dirty working tree or an existing release artifact.
   - Requires an explicit positive build number greater than all versions in both the local and published appcasts. The example `48` is illustrative; choose the next valid number when releasing. A failed feed download stops the release.
   - Runs `xcodegen generate` + a dependency-locked universal (`arm64` + `x86_64`) Release build.
   - Refuses ad-hoc/development signatures or a build without hardened runtime.
   - Submits the app to Apple notarization and staples the accepted ticket.
   - Zips `Swiitch.app` to `build/dist/Swiitch-v0.2.0.zip`.
   - Signs the zip with Sparkle's `sign_update` (uses the Keychain private key).
   - Prints a ready-to-paste `<item>` block.

3. **Publish**:
   - Tag and push: `git tag -a v0.2.0 -m "Release 0.2.0" && git push origin v0.2.0`.
   - Draft a GitHub Release for `v0.2.0`, drag the `.zip` into the assets box.
   - Paste the printed `<item>` block into `appcast.xml` inside `<channel>`.
   - Commit `appcast.xml` + push to `main`.
   - Existing installs receive updates according to Sparkle's schedule when automatic checks are enabled, or through Check for Updates.

`appcast.xml` is served from `https://raw.githubusercontent.com/pernielsentikaer/swiitch/main/appcast.xml` — no GitHub Pages setup needed. The URL is configured in `Info.plist` under `SUFeedURL`.

`build/` is gitignored — release artifacts never land in the repo. The script intentionally fails before packaging when Developer ID signing or notarization is unavailable; do not distribute an ad-hoc build as a public release.

Run `bash Scripts/test_release_gates.sh` for read-only feed validation and an isolated dirty-repository fixture. It does not sign, notarize, contact a server, or commit to this checkout.

## Verification boundaries

Regression tests use injected capture, shortcut, discovery, login-item, and updater backends, plus offscreen SwiftUI renders. They do not revoke permissions, close real documents, register login items, or publish updates. Before a public release, manually check real-window switching/capture across Spaces, two displays, VoiceOver interaction, and the oldest supported macOS. Universal compilation is not an Intel runtime test.

`AccessibilityTests` checks the rendered tile's label, selected state, preview status,
and actions. Some hosted SwiftUI test processes expose no AX children until an external
accessibility client connects; that condition is explicitly skipped, not counted as a
pass. For a local inspection run, set `TEST_RUNNER_SWIITCH_AX_INSPECTION_SECONDS=20`
on `xcodebuild ... -only-testing:SwiitchTests/AccessibilityTests test` and inspect the
synthetic test window during the bounded pause. It never acts on real app windows.

## Code of conduct

Be kind. Assume good intent. Disagree on technical merit, not people.

## License

By contributing, you agree your contribution is licensed under [the MIT License](LICENSE).
