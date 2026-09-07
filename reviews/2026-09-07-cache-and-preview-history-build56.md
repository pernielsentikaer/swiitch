# Scope-aware cache retention and preview history — build 56

Implemented the two approved reliability follow-ups from the build 54 review.
No new UI settings, permission requests, public release or push.

## Changes

1. **Keep live previews across scope filters.** Idle prewarming now reads an unscoped,
   non-excluded identity set from cached discovery for retention. It separately reads
   the current screen/Spaces/minimized scope for missing-image capture. A filtered
   window is no longer treated as closed. Closed and excluded identities are still
   invalidated; cache capacity, freshness limits and capture scheduling are unchanged.
   This reuses existing cached discovery rather than adding another native collection.
2. **Ignore uncommitted app visits.** The shared tracking-suspension flag now covers
   app history as well as window history. Cancelling a preview or releasing an empty
   search preserves both histories. Teardown resumes tracking before a real commit or
   original-window restoration, so ordinary activation and confirmed switches still
   update recency in all four picker modes.

Idle work rechecks its invocation/permission epoch, exclusions and display mode after
async boundaries. A newer picker invocation or changed permission/exclusion state
abandons stale work. The capture scope is read again after cache retention, so a scope
change during that actor hop cannot warm the prior scope. Overlapping idle passes
remain coalesced; an open picker keeps priority over idle work.

## Verification

- Fetched origin and pulled main fast-forward-only; already up to date.
- Created local checkpoint `da36096` for the tested build 54–55 source before editing.
- Added two regressions first; both failed against build 55 as expected (four assertions):
  `/tmp/swiitch-build56-before.log`. App order changed after cancelled/empty previews;
  the real four-second timer pruned a still-live offscreen bitmap and forced recapture.
- Nine new tests cover both regressions, all-mode commits, ordinary app activation,
  display/Space/minimized filters, image identity retention, closed/excluded cleanup,
  uncached hidden windows, scope changes during retention, permission/exclusion changes,
  newer invocations, overlapping passes and picker priority. Focus and metadata are
  injected; the retention tests use the real cache with synthetic images.
- Targeted suite: **173 passed**, zero failures; `/tmp/swiitch-build56-targeted.log`.
- Full English suite: **343 passed, zero failures, one skipped** (344 total):
  `/tmp/swiitch-build56-full.xcresult`, `/tmp/swiitch-build56-full-tests.log`.
  The native minimize/discovery/restore test and externally inspected accessibility
  fixture passed. The separate Debug host lacks Screen Recording permission, so its
  native thumbnail-capture fixture skipped. No permission was requested or reset.
- Danish localization + interaction suite: **54 passed**, zero failures;
  `/tmp/swiitch-build56-danish.log`.
- Universal arm64/x86_64 signed Release build and static analysis passed. All 17 release
  gates, dependency-lock comparison and whitespace checks passed. Existing capture API
  deprecation and AppIntents metadata warnings remain.

## Installed

- Backed up build 55 to `build/backups/Swiitch-Test-build55-20260907.zip`; archive
  integrity verified. Also retained `/private/tmp/swiitch-build56.SAXVLv/Previous-build55.app`.
- Replaced/relaunched `/Applications/Swiitch Test.app` as **0.1.5-dev (56)**; native
  About and the running process confirm it. Installed deep/strict signature verification
  passed, with the same bundle ID and designated signing requirement as build 55.
- Live diagnostics: Accessibility and Screen Recording granted, keyboard ready, login
  enabled, 18 cached previews / 22,173,120 bytes, zero capture failures/timeouts/capacity
  evictions, no active or pending batches. These are a snapshot, not a performance claim.
- Shortcuts, login, menu/Dock visibility and update settings were preserved. Diagnostics
  was inspected, not copied. No private window titles or desktop screenshots are logged
  in this review. Source changes are checkpointed locally; nothing is pushed or released.

## Remaining validation

Hands-on: with preview enabled, preview another app and cancel (also try empty search
and release); the next invocation should preserve prior recency. Switch Spaces/screens
with restrictive scope settings and confirm retained previews reappear without a fresh
load merely because their scope changed. Closed/excluded windows must still disappear.

These deterministic tests do not reproduce physical Spaces, multiple displays, native
notification timing, sleep/wake, full VoiceOver navigation, or macOS 14/Intel runtime.
The separate 80 ms native-focus fallback concern remains an investigation, not a fix
or a confirmed native reproduction in this batch. No universal zero-reload guarantee
or measured CPU/energy savings is claimed.
