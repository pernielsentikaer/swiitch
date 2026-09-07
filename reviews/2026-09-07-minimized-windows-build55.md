# Minimized-window presentation — build 55

Implemented the approved behavior for windows minimized to the Dock (yellow button),
not app-wide Command-H hiding. No unrelated follow-up items from build 54 were changed.

## Behavior

- Preferences → Switcher → Scope now offers **Minimized windows: Show last / Keep in
  recent order / Don’t show**. Show last is the default. A saved opt-out from the old
  inclusion toggle migrates to Don’t show; an explicit new choice wins over legacy data.
- Show last places confirmed minimized windows after normal/unknown-state windows.
  Pins and recent order remain meaningful within each group. Apps-first grouping is
  unchanged, so an app with both normal and minimized windows is not demoted wholesale.
- Each invocation snapshots minimized grouping by process ID and window ID. Refreshes
  can update a window’s state/label without moving its tile or keyboard selection.
  Reopening the picker uses the latest state. New windows get their group on arrival.
- The thumbnail alone is subtly muted; the icon, title, selection outline and actions
  retain their normal appearance. A localized Minimized subtitle is always readable,
  including compact tiles. App names remain in the accessibility label at all sizes.
  VoiceOver announces the state and explains that activation restores the window.
- Search, current-app mode and exact-window activation remain available for minimized
  windows. Existing native restoration and cache paths are retained. Missing thumbnails,
  missing titles, offscreen status or unknown AX state are not treated as minimization.
- The prior screen/Spaces filtering rules still apply independently of this setting.

## Verification

- Fetched origin and pulled main fast-forward-only before work; already up to date.
- Added 15 tests covering migration/reset, all three choices, recent order/pins,
  unknown/reused window identities, current-app scope, mixed-window apps, search,
  minimize/restore reconciliation, and compact/normal rendered previews.
- Full English suite: **334 passed, zero failures, one skipped** (335 total):
  `/tmp/swiitch-build55-full.xcresult`, `/tmp/swiitch-build55-full-tests.log`.
  The only skip was native thumbnail capture: the separate Debug test host has no
  Screen Recording grant. No permission was requested or reset.
- The opt-in native fixture successfully minimized, discovered and restored its own
  disposable window. The externally inspected native accessibility fixture passed;
  its minimized tile remained a button with the correct value, restore hint and
  supported actions, with no hover required.
- Danish suite: **5 passed**, zero failures: `/tmp/swiitch-build55-danish.xcresult`.
  Inspected English/Danish light/dark render attachments; compact labels fit without
  displacing the title or selection outline. Final render exports are under
  `/tmp/swiitch-build55-full-attachments` and `/tmp/swiitch-build55-danish-attachments`.
- Signed universal arm64/x86_64 Release build and static analysis passed. All 17
  release gates, locked-dependency comparison, and whitespace checks passed.
  Existing CGWindowListCreateImage deprecation and AppIntents metadata warnings remain.

## Installed

- Backed up build 54 to `build/backups/Swiitch-Test-build54-20260907.zip` and verified
  archive integrity; retained `/private/tmp/swiitch-build55.nSqhtr/Previous-build54.app`.
- Replaced and relaunched `/Applications/Swiitch Test.app` as **0.1.5-dev (55)**.
  Native About confirms build 55. Deep/strict signature verification passed; the
  bundle ID and designated signing requirement match the previous installed build.
- The live Danish preferences picker shows all three choices with **Vis sidst**
  selected. Existing shortcuts, login, menu/Dock visibility and update settings remain.
  Live diagnostics confirms both permissions granted and keyboard status ready.
  No settings reset, permission reset, public release, commit or push was performed.

Hands-on check: minimize one of two windows in an app, reopen Cmd-Tab, and confirm it
appears last with Minimized/Minimeret while its normal sibling stays in the normal
group. Select it to restore it. Try the other two choices in Preferences. Minimize
from the open picker and confirm the order stays stable until the next invocation.
Physical held-shortcut use across real third-party apps, multiple displays/Spaces,
sleep/wake and older supported macOS versions remains separate from the fixtures.
