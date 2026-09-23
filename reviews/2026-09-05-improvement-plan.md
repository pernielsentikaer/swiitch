# Remaining six-item improvement batch

Goal: finish all six items proposed after build 47. Preserve existing source work,
settings, permission grants, and the installed test app until the replacement is verified.

- [x] 1. Shortcut installation recovery, scoped recorder suspension, conflict validation, regression tests.
- [x] 2. Bounded off-main window discovery, responsive opening with recent snapshots, safe target revalidation, cold/warm/slow-provider evidence.
- [x] 3. Focused-window display selection, including same-app windows on different displays and fallback tests.
- [x] 4. Real login-item status/error/approval UI and automatic update preference respected, with isolated tests.
- [x] 5. User-initiated copyable diagnostics with counts/timings/filtering reasons/version, excluding titles, URLs, screenshots, and other private content.
- [x] 6. Locked dependencies, release-number/dirty-tree gates, Release/universal CI with artifacts, accessible controls, current documentation.
- [x] Final verification: full regression suite, UI renders, static analysis, universal compilation, release-gate checks, signed local install with rollback backup, and item-by-item completion audit.

No public release, commit, push, permission reset, or destructive real-window test is authorized by this maintenance task.

## Completion evidence — 6 September 2026

- **258 passed, zero failed/skipped:** `/private/tmp/swiitch-six-items.f6fiMC/FinalAXRegression.xcresult`.
  The final run used an external AX client during the synthetic accessibility test.
  It asserted the tile label, selected state, preview status, three named actions,
  and default activation. Earlier attempts failed because the host exposed no nodes,
  then because SwiftUI's node does not declare protocol conformance; the fixture now
  queries the public ObjC selectors. Unattended hosts without an AX bridge explicitly
  skip that one test, never report a false pass.
- Universal unsigned Release build and static analysis succeeded, with arm64 and
  x86_64 verified. Existing CGWindowListCreateImage fallback deprecation remains.
- All **17 release-gate fixture checks**, shell syntax, dependency-lock comparison,
  and `git diff --check` pass. CI configuration was validated locally, not run remotely.
- Cold/warm discovery uses a synthetic 200 ms collector; recent-cache preparation
  was approximately 0.01 ms. Non-cooperative timeout/coalescing and exact cached-target
  ID/owner checks pass. This is not installed hotkey-latency benchmarking.
- Installed and relaunched **Swiitch Test 0.1.5-dev (48)**, preserving bundle ID and
  designated signing requirement. Signature and one enabled keyboard tap verified.
  Build 47 has an integrity-checked backup at `build/backups/Swiitch-Test-build47-20260906.zip`.
- Live General/About/Diagnostics inspected in the installed app. Command-Tab recording,
  overlapping Option-Tab rejection, and Escape cancellation worked without changing the
  effective shortcuts. Login/update settings were read, not toggled. Diagnostics was
  reviewed, not copied or shared: both permissions granted, keyboard ready, login enabled,
  18 apps/26 windows after filtering, 34 ms last collection, zero discovery timeouts.
- SwiftUI render attachments cover light/dark layouts. Offscreen snapshots of native
  controls/scrolling have compositing limitations; installed dark-appearance General
  and Diagnostics were visually checked instead of declaring those bitmap gaps a pass.

## Next, separate work

1. Real-window regression matrix: Spaces, multiple displays, wake/reconnect, macOS 14,
   Intel runtime, and full VoiceOver navigation. No permission revocation was simulated live.
2. Window-action capabilities and unobtrusive failure feedback: completed in build 49;
   see `reviews/2026-09-06-window-actions.md` for the implementation and verification.
3. Measure idle CPU/energy and hotkey latency with many windows before tuning discovery
   or capture schedules further. Build 50 adds an installed idle baseline and a 500-window
   model benchmark; physical held-key latency and energy remain separate checks.
4. English/Danish localization is implemented in build 50, including native descriptions
   and accessibility text. See `reviews/2026-09-06-next-improvements.md` for evidence and
   the remaining hands-on validation boundaries.
