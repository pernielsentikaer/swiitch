# Next improvements: search, window scope, performance, validation, localization

User objective: do items 1–5 where they make sense. No public release, push, or
permission reset is part of this work. Preserve the existing development bundle identity.

## 1. Consistent drill-in search

Implemented window-title/app-name search inside an app's window grid, using the same
case/diacritic-insensitive matching as the other modes. The app strip remains stable;
returning to apps restores the previous app query. Selection and row/cycle navigation
resolve visible identities. Empty results cannot focus, peek, hide, close, minimize,
or zoom an invisible window. Refresh preserves the selected window ID.

## 2. Independent minimized-window inclusion

Implemented a separate preference (default on), reset support, and shared direct/cache
filtering. Only AX-confirmed minimized windows bypass the offscreen/Spaces filter;
the selected-screen filter still applies. Unknown AX state remains unknown, not inferred
from missing images/titles. macOS's on-screen list does not identify a minimized window's
Space, so the preference explicitly includes minimized windows independently of Spaces.
Confirmed minimized documents are not classified as decorative/host duplicates.

## Evidence so far

- Current `origin/main` fetched; fast-forward-only pull reports already up to date.
- Targeted Debug run: **133 tests, zero failures**, including new search/scoping,
  preference, cached filtering, and minimized-window/ghost-classifier regressions.
- Test log: `/tmp/swiitch-goal-search-tests.log`.
- Final English Debug run: **291 tests, zero failures/skips**, including live AX
  inspection and the opt-in native minimized-window test:
  `/tmp/swiitch-goal-final-english.xcresult`.
- Universal arm64/x86_64 signed Release build and analysis pass; all 17 release gates
  pass, as do dependency-lock comparison and `git diff --check`.
- Installed and relaunched **Swiitch Test 0.1.5-dev (50)** at the existing path,
  with the same bundle ID and designated signing requirement as build 49.
- Build 49 is retained in `build/backups/Swiitch-Test-build49-20260906.zip` (archive
  integrity checked) and `/private/tmp/swiitch-build50.auEfOd/Previous-build49.app`.
- Native installed UI confirms Danish sidebar, scope preference, preview labels,
  About version, and diagnostics. Both permissions remain granted; keyboard status
  is ready, login is enabled, and discovery reports 23 apps / 31 windows, 103 ms last
  collection, zero timeouts, and one app with unavailable AX metadata. No settings
  were changed or diagnostics copied/shared.

## 3. Performance measurements — local measurements complete

- Build 49 baseline: 31 `top` samples, nominal two-second interval; excluding its first
  sample, mean CPU 3.66% of one core, peak 22.9%; reported memory remained 62 MB.
  Process CPU time rose from 39.43 to 41.83 seconds. This is not a battery-life estimate.
  Raw sample: `/tmp/swiitch-build49-idle-profile.txt`.
- Added a repeatable, isolated Debug model benchmark: 25 synthetic apps / 500 windows,
  100 iterations. Initial run: opening median 0.73 ms / p95 0.83 ms; ten-character
  search plus cycling median 10.30 ms / p95 11.03 ms. This excludes native discovery,
  event-tap dispatch, drawing, captures, and focus. Attachment is in the test result;
  `/tmp/swiitch-goal-performance-tests.log` also records it.
- No speculative polling/capture tuning or CPU-saving claim. Minimized-state reads
  use the existing metadata deadline and run only after every app's window-ID pass,
  so optional metadata cannot starve the ghost-window identity checks.
- Build 50 follow-up: 31 `top` samples; after the first sample, mean CPU 1.01% of one
  core, peak 1.8%, reported memory 61 MB, CPU time 3.90 → 4.59 seconds.
  `/tmp/swiitch-build50-idle-profile.txt`. This was the freshly launched app with
  Preferences/About open and zero thumbnail captures recorded, so it is not a
  like-for-like savings comparison against build 49 or an energy benchmark.
- Actual held-shortcut latency still needs a physical-keyboard run; the available UI
  key-chord call does not reproduce a held modifier session reliably and is not counted
  as a successful hotkey test.

## 4. Real-world validation — partly complete

This machine currently exposes one online display, Apple M4 Max, macOS 27.0 (26A5425a).
- The native test minimizes one of two disposable AppKit windows, verifies AX state
  and both inclusion settings, restores that exact window, and keeps its sibling intact.
  It caught a real bug: `.optionIncludingWindow` omitted minimized windows, so the
  safety check refused to focus them. The fix falls back to `.optionAll` while still
  requiring the exact ID and PID. The failing run and diagnostic run are retained in
  `/tmp/swiitch-goal-native-window.xcresult` and
  `/tmp/swiitch-goal-native-window-diagnostic.xcresult`; the fixed integration/action
  subset passes all 34 tests in `/tmp/swiitch-goal-native-window-fixed.xcresult`.
- External AX inspection and the full test confirm selected state, preview status,
  default activation, and supported/unsupported window action menus without hover.
Multiple physical displays, macOS 14/Intel runtime, and sleep/wake/reconnect need suitable
hardware or user coordination; compilation and mocked tests are not substitutes.
Full VoiceOver navigation remains distinct from verifying exposed accessibility nodes.

## 5. Danish localization — implemented

- 204 localizable UI strings plus four Info.plist entries, using Xcode string catalogs.
  Includes dynamic labels, settings, menus, onboarding, native permission descriptions,
  errors, tooltips, and accessibility actions. Preserves brand/identity, storage keys,
  real application names and real window titles; diagnostic JSON stays machine-readable.
- Compiler-emitted localization keys match the catalog exactly (no missing/unused keys).
- Four dedicated tests pass in Danish: packaging, English fallback, format placeholders,
  derived runtime labels, and preference renders. Results:
  `/tmp/swiitch-goal-danish.xcresult`; renders `/tmp/swiitch-goal-danish-renders/`.
- General/light and Switcher/dark renders were inspected; native build 50's Danish
  sidebar and Scope settings were also visually checked. Offscreen snapshots do not
  reliably composite every native control and are not a substitute for native QA.
- Language follows macOS's app-language selection. No global language preference was
  changed, no app rename, and no permission reset was performed.
- Final Danish subset: **37 tests passed, zero failures/skips**, including externally
  inspected AX actions/status in Danish and all interaction regressions:
  `/tmp/swiitch-goal-final-danish.xcresult`.

## Hands-on pre-release checklist

On 2026-09-06, the user agreed to defer the remaining hands-on checks below until
pre-release. Items 1–5 are complete within that agreed scope; these checks remain
release-validation work, not successful test results.

These items remain unverified, not assumed to pass from compilation or simulated data:

- Physical keyboard: Apps first → choose a multi-window app → ↓ → hold the shortcut
  modifier and type a window title; cycle filtered results, erase to zero matches, and
  release. Empty results must not focus a hidden tile. Go back with ↑ and check that
  the earlier app query is restored. Repeat with normal/all-window and current-app modes.
- Spaces/fullscreen: use two disposable windows on separate Spaces; verify the Spaces
  option, independent minimized inclusion, and exact target restoration.
- Multiple displays: mouse-pointer/active-window/main display placement, screen filter,
  maximum width, and disconnection/reconnection with a window on the secondary display.
- Sleep/wake and session lock/unlock: confirm shortcut readiness, fresh enumeration,
  thumbnails, and no repeated onboarding or permission prompts after returning.
- Full VoiceOver workflow: navigate and activate tiles, hear selected/preview states,
  and inspect available actions in both languages. Exposed AX nodes have been tested;
  a complete assistive-technology workflow has not.
- Supported minimum/other architecture: runtime on macOS 14 and Intel hardware. Universal
  compilation succeeds but does not prove those runtime combinations.
