# Search input and empty-result restoration — build 54

Implemented items 1–2 from the follow-up review of `f2c87e7`. Items 3–4 remain queued.
No new preferences, permission requests, public release, commit, or push.

## 1. Printable punctuation stays inside search

The input handler now accepts punctuation and symbols alongside letters, numbers, and
spaces. Holding Command and typing a comma no longer passes Command-comma through to
the underlying app. The same behavior applies to the current-app shortcut and queued
input during cold opening. Keyboard-layout mapping and shifted symbols are preserved.

Explicit navigation/window actions remain higher priority. The existing backtick
drill-in key remains reserved; non-text function keys retain pass-through behavior.
This is not a new IME/composition implementation or a promise of arbitrary text input.

## 2. Empty-result commits undo previews

Before teardown clears original focus, `commit()` checks for a visible target in its
current mode. When there is none, it uses `cancel()` to restore the exact original
window after a preview, retaining the existing app fallback if exact restoration is
unavailable. Without a preview, empty commits cause no focus operation. A valid
selection still commits normally. Both modifier release and Return follow this path.

## Verification

- Two permanent regression tests failed against the pre-fix code as expected (80
  assertions across keyboard-layout punctuation cases and all four display modes):
  `/tmp/swiitch-build54-before.log`.
- Eight added tests cover both initiating modifiers, shifted punctuation/symbols,
  queued opening input, idle/function-key pass-through, all four modes, no-preview
  empty results, unavailable-original fallback, valid selection, and Return followed
  by modifier release restoring only once. All focus/close operations are injected;
  synthetic events are sent directly to the handler, never posted to user apps.
- Targeted suite: **153 passed**, zero failures; `/tmp/swiitch-build54-targeted.log`.
- Full English suite: **319 passed, zero failures, one skipped**;
  `/tmp/swiitch-build54-full.xcresult`. The separate Debug host lacks Screen Recording
  permission for its native capture fixture. No permission was requested or reset.
- Native AX fixture was externally inspected and passed, as did the native disposable
  minimized-window discovery/restoration test. Physical held-shortcut behavior of these
  new fixes is still a separate hands-on validation boundary.
- Signed universal arm64/x86_64 Release build and static analysis passed, along with
  all 17 release gates, locked-dependency comparison, and whitespace checks. The
  existing CGWindowListCreateImage deprecation and AppIntents metadata warnings remain.

## Installed

- Fetched origin and pulled main fast-forward-only before work; already up to date.
- Backed up build 53 to `build/backups/Swiitch-Test-build53-20260907.zip`; archive integrity
  checked. Also retained `/private/tmp/swiitch-build54.gxejc2/Previous-build53.app`.
- Replaced and relaunched `/Applications/Swiitch Test.app` as **0.1.5-dev (54)** with
  unchanged bundle ID and designated signing requirement. Installed deep/strict code
  signature verification passed; native About confirms build 54.
- General shows unchanged primary/secondary shortcuts, login, menu/Dock visibility,
  and update settings. Diagnostics confirms both permissions granted and keyboard ready.
  Its current snapshot shows 18 apps / 20 windows, 19 cached previews, no active capture
  batches, capture failures/timeouts, or capacity evictions; last discovery took 19 ms.
  No settings or clipboard contents were changed.

Hands-on checks: hold Command while typing punctuation such as a comma into search;
it should appear in the query without opening the underlying app's settings. With
preview enabled, preview another window, type a query with no matches, and release
the shortcut (also try Return): focus should return to the original window.

## Remaining follow-up items (not implemented here)

Follow-up: items 3–4 below were implemented and verified in **build 56**; see
`2026-09-07-cache-and-preview-history-build56.md`. The descriptions below retain the
original findings. The separate delayed native-focus retry investigation remains open.

3. **App recency after cancelled preview:** window history is suspended during previews,
   but FocusTracker's app-activation callback still bumps app history. A,C,B becomes
   A,B,C after previewing B and cancelling back to A. Suspend preview-only app visits
   while preserving real commits. Reproduced with an injected activation callback.
4. **Cache retention across Spaces/displays:** idle prewarming uses the filtered scope
   as its live-window retention set. A still-live offscreen window loses its cached
   preview when other Spaces are hidden, with no capacity eviction counted. Retention
   should use all live, non-excluded identities, independently of what needs prewarming.
   Reproduced using the real four-second timer, synthetic windows, and the real cache.

Original review/probe evidence is in `/private/tmp/swiitch-review-next.RXy39v/`.
Also retain the source-review question about stale 80 ms native activation retries;
no native reproduction or change was attempted in this batch. Previously deferred
multi-display/Spaces/wake/minimum-OS/VoiceOver checks remain pre-release work.
