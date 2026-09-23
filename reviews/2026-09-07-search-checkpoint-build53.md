# Multi-word search and local checkpoint — build 53

Scope approved by the user: smarter search, preserve the accumulated intended work in
a local Git checkpoint, and perform safe performance checks. No push or public release.
Hardware-dependent and physical-keyboard checks remain on the agreed pre-release list.

## Search

- Split the query into whitespace-separated words once per filtering pass. Every word
  must match the app name or the same window's title, in any order. For example,
  `dia calendar` and `calendar dia` find a Calendar window belonging to Dia.
- Preserve case/diacritic-insensitive matching, literal punctuation, current-app scope,
  drill-in behavior, and recent-window ordering. Whitespace alone does not filter.
- Apps-first search can match a multi-word app name even without windows. Words found
  only in different sibling windows cannot combine into a spurious matching app.
- Six added regression tests cover every mode, accent/punctuation handling, empty-result
  action safety, ordering, and space-separated input under Command and Option bindings.
  Keyboard tests call the input handler directly; they never post events to user apps.

## Verification

- Targeted tests: **148 passed**, zero failures, in `/tmp/swiitch-build53-targeted.log`.
- Full English suite: **311 passed, zero failures, one skipped** in
  `/tmp/swiitch-build53-full.xcresult`. The separate Debug host lacks Screen Recording
  permission for the native thumbnail fixture; no grant was requested or reset.
- External AX inspection initialized the native accessibility fixture. Its assertions
  passed, as did native minimized-window discovery and exact restoration.
- Signed universal arm64/x86_64 Release build and static analysis passed:
  `/tmp/swiitch-build53-release.log`. All 17 release gates, dependency-lock comparison,
  and whitespace checks passed. Installed deep/strict signature verification passed.

## Performance evidence and limits

- Used build 52's real diagnostics reported **32 windows and 32 cached previews**, using
  **40,224,960 bytes (38.36 MiB)** with **zero capacity evictions**. No active captures,
  pending windows, backoff windows, or capture timeouts. There were two historical failed
  captures over that process's lifetime, not two currently pending failures. Discovery
  last took 62 ms, with zero timeouts and no unavailable AX apps.
- Build 52 used-idle sample, with About open: 21 samples at nominal two-second intervals.
  Excluding the first sample, mean CPU **1.82% of one core**, peak **2.3%**, reported
  memory **292 MB**, CPU time **27:34.28 → 27:35.11**.
  Raw data: `/tmp/swiitch-build52-used-idle-20260907.txt`.
- Build 53 fresh-idle sample, with About open: same sample count and interval; excluding
  the first, mean CPU **1.08% of one core**, peak **1.9%**, reported memory **49 MB**,
  CPU time **00:01.68 → 00:02.18**. Raw data:
  `/tmp/swiitch-build53-fresh-idle-20260907.txt`.
- Those memory/CPU samples are **not a like-for-like savings comparison**: build 52 had
  been used extensively and had a populated cache; build 53 was freshly launched with
  no captures yet. No leak, battery-life, or energy-saving conclusion is drawn.
- Existing isolated Debug benchmark (25 apps / 500 synthetic windows, 100 iterations):
  opening median **0.81 ms**, p95 **0.99 ms**; typing ten characters plus cycling median
  **20.27 ms**, p95 **21.07 ms**. This measures model work, not native discovery, capture,
  drawing, event-tap dispatch, or focus. It is not measured physical Cmd+Tab latency.

## Delivery and checkpoint scope

- Fetched `origin` and performed a fast-forward-only pull from `main` before work and
  again before the checkpoint; already up to date. Existing work was not reset or stashed.
- Checkpoint includes the accumulated Swiitch source, tests, localization catalogs,
  dependency lock, release gates, and review/developer documentation. Rechecked native
  action identity guards, permission/lifecycle handling, diagnostics privacy, and release
  packaging boundaries. This is a preservation checkpoint, not a new exhaustive audit.
- Repository credential-pattern scan found no matches. Local signing configuration,
  `.env`, `.env.*`, `.dev.vars`, generated projects, and build/backup artifacts remain
  ignored and are not part of the checkpoint.
- Backed up build 52 as `build/backups/Swiitch-Test-build52-20260907.zip`; archive
  integrity passed. Also retained `/private/tmp/swiitch-build53.SG2R2L/Previous-build52.app`.
- Replaced and relaunched `/Applications/Swiitch Test.app` as **0.1.5-dev (53)** with
  the same bundle ID and designated signing requirement. Native About confirms 53.
- Native General confirms existing shortcuts, login, visibility, and automatic-update
  settings. Diagnostics confirms both permissions granted and keyboard ready, with
  24 apps / 32 windows, 73 ms last collection, zero discovery timeouts. No settings or
  clipboard contents were changed. Fresh in-memory thumbnail caches start empty.

Suggested hands-on test: hold the usual shortcut, type an app name plus a word from a
window title, then release to select the result. Repeat in current-app and drill-in modes.
The multi-display/Spaces/wake/minimum-OS/VoiceOver matrix remains deferred to pre-release.
