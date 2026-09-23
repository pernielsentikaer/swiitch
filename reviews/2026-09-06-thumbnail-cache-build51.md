# Thumbnail cache retention — build 51

## Diagnosis

The installed build 50 reported about 30 live windows but only 19 cached previews,
using 95,673,600 bytes of the 96 MiB cache budget. Capture failures/timeouts and
permission failures were zero. The user reported a subset reloading on each opening.

An isolated production-cache probe with synthetic oversized previews retained 19 of
31 entries and recaptured 12 on each later pass. Properly bounded previews retained
all 31 and required no later captures. The probe read no screen contents.

The first new regression run exposed the more precise issue: even after downscaling
to 720 pixels, `NSImage(cgImage:size:)` produced a 1440-pixel backing representation
on this Retina machine. This quadrupled per-entry cache cost. The failing run is
retained in `/tmp/swiitch-build51-thumbnail-tests.log`; it reported 13 failed assertions
covering dimensions, cache size, retained count, and unnecessary recapture.

## Changes

- Both native capture paths normalize the returned bitmap to a maximum 720-pixel
  long edge and an 8-bit RGBA representation before delivering to the cache or UI.
- An explicit `NSBitmapImageRep` preserves the actual bitmap dimensions rather than
  allowing a display-scaled snapshot representation.
- Warm cached previews are delivered within one main-actor turn, avoiding separate
  UI turns between each restored preview. Fresh captures still stream progressively.
- Cache limits, freshness, invalidation, cancellation, permission checks, and the
  separation between preview availability and window eligibility remain unchanged.

## Validation

- Focused suite: 28 passed, zero failures. All 31 normalized 720×440 previews remain
  cached across three passes at 39,283,200 bytes, with one capture batch total.
- Full suite: 294 passed, zero failures, one skipped. The new native screenshot test
  uses only its own disposable window and was skipped because the separate test host
  lacks Screen Recording permission. No permission was requested or reset.
- Full result: `/tmp/swiitch-build51-full.xcresult`.
- Live AX inspection initialized the test window's accessibility tree; its assertions
  passed. Native minimize/discovery/exact-restore integration also passed.
- Universal arm64/x86_64 Release build and analysis passed. All 17 release gates,
  dependency-lock comparison, and `git diff --check` passed.

## Installed for testing

- Replaced and relaunched `/Applications/Swiitch Test.app` as **0.1.5-dev (51)**.
- Same bundle ID, development certificate, and designated signing requirement as 50.
  Installed deep/strict signature verification passed.
- Native About confirms build 51. Diagnostics confirms both permissions remain
  granted, keyboard ready, and launch-at-login enabled. Existing hotkeys and visibility
  preferences remain unchanged.
- Build 50 backup: `build/backups/Swiitch-Test-build50-20260906.zip` (integrity checked),
  plus `/private/tmp/swiitch-build51.Yzgqca/Previous-build50.app`.
- The restarted app naturally has an empty in-memory cache until first use. Physical
  Cmd+Tab repeated-opening behaviour still needs the user's test; the available UI
  key-chord tool is not a reliable held-modifier test.

User workflow: after each implemented change, test and deliver a new numbered build,
back up and replace the installed test app, relaunch it, and state what to test. Preserve
settings and signing identity; never reset permissions as a routine update step.
