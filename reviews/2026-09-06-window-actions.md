# Window-action feedback and safety — build 49

Implemented on 6 September 2026, preserving the existing worktree changes.

## Changes

- Close, Minimize, and Zoom now distinguish accepted requests, missing Accessibility
  permission, missing windows, unresolved identity, unsupported/disabled controls, and
  generic failures. Native calls still revalidate the exact window ID and owner and never
  force-quit or bypass unsaved-changes prompts.
- Native action resolution checks exact IDs before optional metadata and bounds AX
  messaging time. Capability inspection uses two bounded background slots, runs only
  for selected/hovered windows, coalesces requests, and briefly caches results. There is
  no new idle polling. Unknown metadata does not permanently disable a usable action.
- Confirmed unavailable traffic lights are gray with explanatory help, and unavailable
  actions are omitted from the tile's VoiceOver action menu. Actions recheck capabilities
  at execution rather than treating a cached hint as authority.
- Failures show a five-second message in the search badge's reserved space and announce
  through Accessibility. Selection and tile positions are preserved; search, success,
  and cancellation clear the message. The fixed header is included in the panel height
  budget to avoid clipping a full grid.
- Explicit window controls reject stale callbacks targeting filtered-out windows or
  windows outside the current-app/drill-in scope. Session changes, mutations, and owner
  changes invalidate pending capability results.
- Cancelling a shortcut recording now clears its validation warning. The Window actions
  preference explains dimmed controls and correctly names Control-Command-H for Hide
  with the default shortcut.

## Verification

- **275 tests passed, zero failed/skipped**, including 17 additions and extended live
  accessibility assertions: `/private/tmp/swiitch-actions49.0uKX0n/FinalVerified.xcresult`.
- The external AX inspection showed a normal tile exposing Close/Minimize/Zoom and a
  limited tile exposing only Zoom; the test asserted the same menu and activation behavior.
- Light/dark feedback and disabled-control renders were visually inspected:
  `/private/tmp/swiitch-actions49.0uKX0n/Renders/`.
- Universal arm64/x86_64 Release compilation and static analysis succeeded. The existing
  CGWindowListCreateImage fallback deprecation remains. Shell syntax, dependency lock,
  whitespace, and all 17 release-gate checks pass.
- Signed, installed, and relaunched `/Applications/Swiitch Test.app` as **0.1.5-dev (49)**.
  Bundle ID and designated signing requirement match build 48. The previous app has an
  integrity-checked backup at `build/backups/Swiitch-Test-build48-20260906.zip`.
- Installed-app smoke check: conflicting shortcut rejected, Escape cleared the warning
  without changing the binding, and Option-Tab from Preferences stayed in Swiitch Test.
  The primary-shortcut smoke attempt was stopped by the UI's intervening-change guard
  and was not counted as verified in this batch.

## Boundaries

No real user documents were closed, minimized, zoomed, or hidden to test failure paths;
those tests use injected backends and disposable UI fixtures. No permission resets,
login/update preference changes, clipboard sharing, public release, commit, or push.
The multi-display/Spaces/sleep-wake matrix, Intel runtime, macOS 14 runtime, and a complete
VoiceOver workflow still need separate hands-on testing. CPU/energy savings were not
benchmarked; the narrow on-demand inspection design is not a battery-life claim.
