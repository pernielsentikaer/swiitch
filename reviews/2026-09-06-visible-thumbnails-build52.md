# Visible thumbnail refresh and cache diagnostics — build 52

Implemented requested items 1–2 only. Multi-word search was not changed.

## Relevant preview refresh

- SwiftUI reports tile rectangles relative to the actual scroll viewport. Positive-area
  intersection determines visibility, rather than LazyVGrid's prefetched/on-appear set.
  Geometry helpers do not affect layout, hit testing, or accessibility content.
- Periodic refresh intersects the search-filtered window scope with visible tiles,
  retaining the selected target while it scrolls into view. Before geometry is available,
  it falls back to the filtered scope. Empty search results never capture a hidden selection.
- Scrolling/query changes request newly visible previews with normal cache freshness,
  not forced recapture. Hidden images stay retained. Initial cache fill and background
  missing-only prewarming are unchanged; this is not a promise that hidden windows are
  never captured at all.
- Geometry is stamped with invocation generation, permission epoch, mode, drilled app,
  and query. Delayed reports/tasks cannot restrict a later scope or invocation.

## Aggregate diagnostics

- `cacheHits` and `cacheMisses`: lifetime lookups, counted once per unique window in a
  request. A cached but stale/forced-refresh image still counts as a hit. In-flight or
  backoff misses are lookups, not necessarily new native capture attempts.
- `cacheEvictions`: removals due to the entry/memory budget only. Window cleanup,
  explicit invalidation, and permission clears do not count as capacity pressure.
- Counters survive cache clears and reset with the app/cache instance. They add only
  integer aggregates to the existing review-before-copy report. No titles, app names,
  window IDs, images, URLs, or paths were added. No automatic sharing or new preference.

## Verification

- Targeted suite: **42 passed**, zero failures. Covers all three window modes, selected
  targets, empty filters, retained images, newly visible cells, stale geometry, permission
  revocation/closed sessions, and exact cache counter semantics.
- A hosted production SwitcherView with 40 synthetic windows refreshed 10 initially,
  then 11 after scrolling to the final row. Real native scroll geometry was exercised;
  no user windows were manipulated and no native screen capture was needed.
- Full English suite: **305 passed, zero failures, one skipped** in
  `/tmp/swiitch-build52-full.xcresult`. The native screenshot fixture remains skipped
  because the separate test host lacks Screen Recording permission; no grant was requested.
- External AX inspection initialized the accessibility fixture and all its assertions
  passed. Native minimized-window discovery/restoration also passed.
- Universal arm64/x86_64 signed Release build and static analysis passed, along with all
  17 release gates, dependency-lock comparison, and `git diff --check`.
- No CPU/energy savings or physical held-key performance claim is made from these tests.

## Delivered

- Backed up build 51 as `build/backups/Swiitch-Test-build51-20260906.zip`; archive
  integrity passed. Also retained `/private/tmp/swiitch-build52.4oIaN3/Previous-build51.app`.
- Replaced and relaunched `/Applications/Swiitch Test.app` as **0.1.5-dev (52)**,
  preserving bundle ID and designated signing requirement. Installed signature verified.
- Native About confirms 52. General confirms the existing shortcuts/login/visibility
  settings. Diagnostics displays the three new counters and confirms both permissions
  granted and keyboard ready. No settings, clipboard, TCC grants, or update toggles changed.
- The freshly restarted app has no cached previews until first use. Repeated physical
  Cmd+Tab, filtering, and scrolling still need the user's hands-on check. The previously
  deferred multi-display/Spaces/wake/minimum-OS/VoiceOver matrix remains pre-release work.
- No commit, push, or public release was performed.
