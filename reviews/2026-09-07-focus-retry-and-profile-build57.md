# Superseded activation retries and performance check — build 57

Scoped follow-up to build 56: investigate the delayed native activation retry and
measure the current app before further performance tuning. No new setting, public
release, permission request/reset, or push.

## Finding and fix

`WindowFocuser.activate` queued an 80 ms WindowServer fallback which checked only
whether its target PID was already frontmost. An older preview/switch could therefore
activate after a newer focus request or cancellation. Restoring a window in an app
which was already active returned without calling `activate`, leaving the old retry
alive. This is established from source and deterministic queued-callback tests, not
a reproduced native timing race between the user's applications.

- One main-actor coordinator now invalidates older callbacks when a newer request
  arrives. Each callback is one-shot and checks whether activation is still needed.
- Every native focus entry invalidates the old request before identity validation,
  including invalid/closed targets and already-active app restoration.
- Preparing/opening a new picker, changing/cancelling a preview, teardown, and window
  actions invalidate pending preview activation. Committing still schedules its own
  fallback after teardown. Late SwiftUI hover-exit callbacks after dismissal cannot
  cancel that committed request.
- At execution, the target application must still be alive and the requested window
  identity must still exist. A fallback cannot activate over a third application that
  became frontmost in the meantime; unknown source/current focus fails closed.
- The 80 ms timing and existing optional SkyLight fallback are unchanged. Capability
  reads remain off the main actor; no polling, capture, cache-limit, or UI changes.

## Verification

- Fetched origin and pulled main fast-forward-only; already up to date.
- Extracted the existing unguarded callback into an injectable seam, then ran two
  regression tests: both failed as expected (older target activated after the newer
  target, and cancelled activation still executed). `/tmp/swiitch-build57-before.log`.
- Twelve new tests cover supersession, cancellation without another activation,
  one-shot execution, changed/unknown frontmost app, released coordinator, all native
  entry points, picker preparation/modes, empty-result cancellation, list teardown,
  selection changes, window actions, and late hover-exit after commit. They inject
  activation/metadata rather than operating on user windows.
- Initial focused run: **126 passed**, zero failures. Three further edge-case tests
  were added and included in the final full suite.
- Final English suite: **355 passed, zero failures, one skipped** (356 total).
  `/tmp/swiitch-build57-full.xcresult`, `/tmp/swiitch-build57-full-tests.log`.
  The native disposable-window minimize/discovery/restore test and externally inspected
  accessibility-node test passed. The separate Debug host lacks Screen Recording
  permission, so native thumbnail capture skipped; no grant was requested or reset.
- Danish localization and interaction suite: **60 passed**, zero failures;
  `/tmp/swiitch-build57-danish.log`.
- Universal arm64/x86_64 signed Release build and static analysis passed. Deep/strict
  signatures, all 17 release gates, dependency-lock comparison, and whitespace checks
  passed. Existing CGWindowList capture deprecation and AppIntents metadata warnings
  remain. A CATransaction warning appeared in the hosted-thumbnail fixture; no test
  failed, and this run does not establish its origin or installed-app impact.

## Performance observations

- Build 56, PID 6139: 31 `top` samples, nominal two-second interval, approximately
  66 seconds. Excluding the initial sample: **1.66% mean CPU of one core**, **2.4% peak**,
  reported memory **62 MB** throughout. Process CPU time: 08:47.61 to 08:48.76.
  `/tmp/swiitch-build56-idle-profile.txt`. No automated picker interaction occurred
  during sampling; this is a local quiet-period observation, not a controlled energy
  measurement or comparison against earlier builds with different workloads.
- Build 56 diagnostics after sampling: 19 apps / 23 windows, 23 cached previews,
  27,157,696 cache bytes, 117,727 hits / 65 misses, zero capacity evictions/timeouts,
  three historical failed captures, no active/pending/backoff work. The snapshot does
  not identify why those three captures failed or imply they are ongoing failures.
- Repeated synthetic Debug model benchmark: 25 apps / 500 windows, 100 openings;
  opening median **0.97 ms**, p95 **1.07 ms**; ten-character search plus cycling median
  **19.12 ms**, p95 **20.28 ms**. Similar to build 56's recorded full-suite numbers
  (0.99/1.09 ms and 19.33/20.55 ms). This excludes native discovery, capture, rendering,
  event-tap dispatch, and focus latency. It does not prove a speed improvement.
- No speculative performance changes made. Physical held-shortcut responsiveness
  and many-window rendering still require hands-on validation.

## Installed

- Backed up build 56 to `build/backups/Swiitch-Test-build56-20260907.zip`; archive
  integrity verified. Also retained `/private/tmp/swiitch-build57.L1XZ7e/Previous-build56.app`.
- Installed and launched `/Applications/Swiitch Test.app` as **0.1.5-dev (57)**.
  About, bundle metadata, and running process PID 99057 confirm the new build.
  Deep/strict signature verification passed; bundle ID and designated signing
  requirement match build 56.
- Live diagnostics confirm Accessibility and Screen Recording granted, keyboard ready,
  and login enabled. General confirms both shortcuts and menu/Dock/update settings
  preserved. No permission prompt or reset. The newly launched process has not yet
  captured previews; zero capture counters are not a successful capture test.
- Diagnostics were inspected, not copied/shared. No user window titles, screenshots,
  or application lists are saved in this review.
- Source and this review are checkpointed locally; nothing has been pushed or released.

## Hands-on handoff

With live preview enabled, preview another app, then press Escape; also try an empty
search and release. Focus should stay with the original window. Commit a switch and
immediately open the picker again: an older target must not pull focus back. Confirm
normal switching, including between two Dia windows, still works.

Physical keyboard timing, multiple displays, Spaces/fullscreen, sleep/wake, full
VoiceOver navigation, and macOS 14/Intel runtime remain unverified. Universal
compilation and disposable native fixtures are not substitutes for those checks.
