# Swiitch project review — 5 September 2026

## Recommendation

Prioritize dependable switching and safe window actions before adding more settings. The current design already has substantial functionality; the highest-value improvements are accurate targeting, predictable keyboard sessions, fresh thumbnails, and conservative window filtering.

The original review below records the pre-fix snapshot. Existing source changes were preserved.

## Follow-up: first implementation batch

P1 findings 1–3 were addressed locally on 5 September 2026:

- Close, Minimize, and Zoom now use a separate strict matching policy. A known different window ID is rejected, and an unavailable ID requires one unique title-and-bounds match. Existing focus fallbacks are unchanged.
- Extra Shift correctly reverses both configured shortcuts. Exact custom bindings take precedence over derived reverse variants, and optional standalone Shift cycling does not double-advance the following Shift-Tab.
- Input sessions capture their initiating modifiers before deferred UI work. Rapid releases, pending navigation/cancellation, and back-to-back sessions remain ordered. Releasing any required modifier commits; releasing optional reverse Shift alone does not. Uninstall invalidates pending operations.
- Added 34 permanent, isolated regression tests: [HotkeyManagerTests.swift](/Users/pernielsentikaer/projects/swiitch/SwiitchTests/HotkeyManagerTests.swift) and [WindowActionMatchingTests.swift](/Users/pernielsentikaer/projects/swiitch/SwiitchTests/WindowActionMatchingTests.swift). These include release/uninstall re-entry during enumeration, not only events arriving before opening starts.
- The full suite now passes **116 tests, zero failed/skipped**. [Test results](/private/tmp/swiitch-p1-20260905-verified.xcresult).
- Final static analysis and unsigned universal Release build both pass; the executable contains arm64 and x86_64. The existing CGWindowListCreateImage deprecation warning remains. This is compile/test verification, not an installed-app or Intel runtime test.

The remaining P2 findings and feature recommendations below are not yet implemented. No real-window destructive actions were tested, and no commit or push was made. Original source-line references below refer to the audit snapshot and may shift after these edits.

### Local test installation

At the user's subsequent request, built, signed, installed, and relaunched [Swiitch Test.app](</Applications/Swiitch Test.app>) as **0.1.5-dev (41)**. The bundle identifier and designated signing requirement match the previous build 40; preference files and permission grants were not reset. Verified the installed signature, executable path, version, and one enabled keyboard event tap in the new process. Screen Recording and every interactive switching scenario were not separately revalidated during installation.

The previous build is preserved in [Swiitch-Test-build40-20260905.zip](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build40-20260905.zip), with archive integrity verified. This is a signed local Debug/test installation, not a notarized public release.

### Search shortcut follow-up — installed build 42

The user reported that typing “chat” while holding Command produced “cat” and hid an app. A synthetic-event regression reproduced exactly “cat” before the fix. H/W now remain search letters; Close/Hide require Control-Command-W/H with at least one action modifier added beyond the opening shortcut. Bindings already requiring both modifiers keep H/W as text. README shortcuts were updated.

Added nine regression tests covering normal and pending search, first-letter H/W, capitals, current-app mode, custom opening modifiers, explicit actions, and pass-through outside Swiitch. The full suite passes **125 tests**, with zero failures/skips; static analysis and the signed local build pass. [Regression results](/private/tmp/swiitch-search42.6CDRi3/After.xcresult).

Installed and relaunched **0.1.5-dev (42)** at the same Applications path and with the same designated signing requirement. Verified the installed signature/version/process and one enabled keyboard event tap. No settings or permission grants were reset. Build 41 is preserved in [Swiitch-Test-build41-20260905.zip](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build41-20260905.zip). Search/actions were verified with isolated synthetic events, not by hiding or closing the user's real windows.

### Per-window recent history — installed build 43

Implemented the per-window history recommendation below. FocusTracker now maintains a bounded, in-memory history of process/window IDs and observes focused/main-window changes for the foreground application via Accessibility notifications. App activation attaches the observer; invocation retries attachment when AX was previously unavailable. Termination clears that process's history. No extra polling loop or permission request was added.

Each invocation records the actual focused window and snapshots the ordering. The all-windows list uses global window recency instead of app grouping; current-app mode and app drill-in use the same history within their scope. Pinned apps retain priority, unseen windows retain their fallback order, and committed targets are remembered even if the next AX read is unavailable. Tracking is suspended during the picker so hover-peek does not count as a committed visit; explicit list refreshes reuse the invocation's history snapshot.

Added **18 regression tests** for successive Dia swaps, external focus changes at invocation, global ordering, current-app scoping, drill-in, unavailable AX reads, preview/refresh stability, pin priority, history bounds, snapshot isolation, and process identity/termination. The full suite passes **143 tests, zero failures/skips**. [Test results](/private/tmp/swiitch-window-mru43.m3Y1ss/Verified.xcresult). Static analysis, whitespace checks, and the signed local Debug build pass. Existing focused-window tests now assert the new tile positions while retaining their target-window assertions.

Installed and relaunched **0.1.5-dev (43)** at [Swiitch Test.app](</Applications/Swiitch Test.app>). Verified its signature, unchanged designated signing requirement, version, running executable, and enabled keyboard event tap. Build 42 is preserved in [Swiitch-Test-build42-20260905.zip](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build42-20260905.zip), with archive integrity checked. Settings and TCC grants were not reset. The actual Dia window pair and native AX notification delivery were not manually exercised; ordering/action regressions use isolated fixtures, not the user's documents. No commit or push was made.

### Interaction reliability — installed build 44

Addressed P2 findings **4, 5, and 9** from the original review:

- Escape after hover-peek saves the original process/window identity before teardown and restores that exact window, including siblings within Dia and originals excluded from the picker. Native restoration deliberately refuses title/single-window matching fallbacks. If the original is unavailable, cancellation falls back to its app only when another app is frontmost. Successful restoration repairs app/window recent-use history.
- App and window click handlers now call identity-based commit methods. They do not require prior mouse movement, resolve against the current visible list, ignore removed/filtered-out identities, respect current-app scope, and support clicking the app strip while drilled into windows. The movement guard remains on hover selection.
- Apps mode chooses the first/last alternative to the actual frontmost PID, so pins cannot make the opening press select the current app when an alternative exists. Bundle identity is used only if PID is unavailable; a known unlisted foreground app no longer causes the first available app to be skipped.

Three directed tests reproduced the Escape and forward/reverse pinned-selection bugs before changes. [Before results](/private/tmp/swiitch-interaction44.ul65gE/Before.xcresult). Added **29 regression tests** in total, including click identity, removed targets, filtering/scoping, missing originals, failed restoration, strict native matching, and every permutation of three apps with both opening directions. The full suite passes **172 tests, zero failures/skips**. [After results](/private/tmp/swiitch-interaction44.ul65gE/After.xcresult). Static analysis, whitespace checks, and signed local Debug build pass. The existing capture fallback deprecation warning remains.

Installed and relaunched **0.1.5-dev (44)** at [Swiitch Test.app](</Applications/Swiitch Test.app>). Verified the matching designated signing requirement, installed signature/version/process, and enabled keyboard event tap. Build 43 is preserved in [Swiitch-Test-build43-20260905.zip](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build43-20260905.zip), with archive integrity checked. No settings or TCC grants were reset. Mouse/preview behavior was tested through isolated model/native-matching fixtures and verified UI wiring, not by manipulating the user's live windows. Thumbnail freshness and the production-layout preferences preview remain outside this batch. No commit or push was made.

## Follow-up: thumbnail freshness and layout preview

Implemented the remaining bounded reliability/preview batch on 5 September 2026:

- Opening the picker immediately delivers cached images and refreshes captures older than three seconds. Cache reads do not extend image age. Failed refreshes retain the last usable image and remain eligible for retry. Concurrent requests still share captures, and the existing count/byte/concurrency limits remain intact.
- Background prewarming fills missing images without refreshing every cached window on its four-second timer. The existing foreground live-refresh behavior is retained.
- Per-window invalidation and cache clearing revoke cached and in-flight results together. A late capture cannot repopulate an invalidated cache entry. Removing one window does not cancel the other windows in its capture batch; cancelling prewarm does not discard a usable cached fallback.
- Preferences now shares a scaled sample preview between Switcher → Layout and Appearance, using the real AppCell/WindowCell views, panel width limits, and grid-sizing functions. It shows the maximum-width boundary, row/column counts, overflow, and sample counts of 6/12/24/40. Layout always demonstrates a window grid, even when Apps is the opening mode, so Automatic/Fill Screen changes remain visible. It is a standalone grid example, not a simulation of the full app drill-in strip. All sample content is synthetic and requires no capture permission.

Added **21 tests** for freshness, retry/fallback, coalescing, invalidation/cancellation, production-grid parity, width/sample-count changes, and rendering. The full suite passes **193 tests with zero failures/skips**. [Test result](/private/tmp/swiitch-preview45.UzueC5/FinalTests.xcresult). Six offscreen NSHostingView render scenarios cover light/dark, Automatic/Fill Screen, Apps, and the full preview controls at 30% width; rendered images were visually checked. ImageRenderer was unsuitable for this test because it omitted AppKit-backed scroll-view content. Static analysis, whitespace checks, and the signed Debug build pass. The intentional legacy capture fallback deprecation warning remains.

Installed and relaunched **0.1.5-dev (45)** at [Swiitch Test.app](</Applications/Swiitch Test.app>). Verified the installed signature and unchanged designated signing requirement, version, process, and one enabled keyboard event tap. Preserved and integrity-checked [build 44 backup](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build44-20260905.zip). No preferences or TCC grants were reset. Capture timing/failure behavior was verified with deterministic providers; fresh capture of the user's actual windows across Spaces, multi-display interaction, Intel, and macOS 14 remain manual validation boundaries. No commit or push was made.

## Follow-up: conservative filtering, search drill-in, and contrast

Implemented the next three-item batch on 5 September 2026:

- Removed the repeated-compact-size heuristic. Similarly sized notes/documents, including off-screen and untitled ones, are no longer discarded just because a larger sibling exists. Unpublished helper windows are still filtered using matching Accessibility IDs; the existing host, decorative-wrapper, same-frame duplicate, and placeholder checks remain. With unavailable, empty, or fully mismatched AX metadata, small dimensions alone are not enough to hide a window. The earlier test that required dropping arbitrary titled compact windows was changed to reflect this conservative policy.
- `enterWindowMode` now requires the selected app to be in the visible search results. A no-match query is preserved, Down/direct drill-in does nothing, and no thumbnail work starts. Valid app/window-title matches still drill in and clear the app-level query, and clearing a no-match search restores normal drill-in.
- Solid Light and Solid Dark now impose a matching semantic foreground color scheme on the switcher surface and its preview. Adaptive materials keep following the app/system appearance. This uses a local environment override, not an app/window-wide preferred appearance, so the surrounding Preferences UI does not change theme.

Directed pre-fix verification reproduced **six failing tests** across compact-window filtering and no-results drill-in. [Before result](/private/tmp/swiitch-polish46.5GT5uZ/Before.xcresult). Before/after offscreen renders also demonstrated and corrected white-on-light/black-on-dark labels and template icons. Added **14 tests** overall, plus updated the two size-heuristic tests; the full suite passes **207 tests with zero failures/skips**. [After result](/private/tmp/swiitch-polish46.5GT5uZ/After.xcresult). Appearance tests cover all materials, light/dark changes, and isolation from the surrounding view. Both app and window previews were visually checked with each fixed material against the opposite app appearance. Existing helper-window regression tests, static analysis, whitespace checks, and the signed Debug build pass. The intentional legacy capture fallback deprecation warning remains.

Installed and relaunched **0.1.5-dev (46)** at [Swiitch Test.app](</Applications/Swiitch Test.app>). Verified its signature, unchanged designated signing requirement, version/process, and one enabled keyboard event tap. Preserved and integrity-checked [build 45 backup](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build45-20260905.zip). No preferences or TCC grants were reset. Filtering/navigation were verified with synthetic window and Accessibility fixtures, not by manipulating the user's live app windows. No commit or push was made.

## Follow-up: capture deadlines, recovery, and thumbnail states

Implemented the next bounded reliability batch on 5 September 2026:

- Native content lookup, ScreenCaptureKit screenshots, and the legacy Core Graphics fallback now have individual deadlines. An eight-second outer batch deadline resolves unfinished requests without discarding previews already delivered. Unlike a task-group timeout race, the deadline runner releases its caller even if the underlying OS operation ignores cancellation. Outstanding native operations retain one of four slots until they actually return; provider batches are independently capped at two. This bounds abandoned work but cannot forcibly terminate a hung OS call.
- Failed windows retry with exponential backoff (2, 4, 8, 16, then at most every 30 seconds), including forced refresh requests. Successful captures reset the backoff. Retry metadata is bounded, and a failed or stalled refresh keeps the last usable cached image. Foreground requests prioritize the selected window; periodic refreshes and background prewarming no longer stack overlapping model loads.
- Added loading, unavailable, and Screen Recording required states to the real window cells. Compact tiles show a status symbol, while larger tiles include explanatory text; hover help and accessibility labels retain the full explanation. Cached previews remain visible during refresh. These states never remove a window or disable ordinary switching.
- An app-lifetime, non-prompting permission monitor forwards Screen Recording changes to the model/cache. Observed denial clears cached and displayed images, cancels pending work, and invalidates late deliveries. Serialized transitions prevent rapid deny/grant changes from clearing newer captures; granting access allows immediate retries and reloads an open picker. No TCC reset or programmatic permission request was added.

Added **17 regression/render tests**; the full suite passes **224 tests with zero failures/skips**. [Final test results](/private/tmp/swiitch-capture47.WfK4rc/FinalTests.xcresult). Coverage includes non-cooperative stalled operations, bounded worker counts, cached fallback, retry backoff, denial during capture, rapid permission transitions, late results after a newer capture or dismissal, and model refresh coalescing. Offscreen real-cell renders were visually checked in light/dark appearance at compact and normal sizes; that check prompted icon-only treatment for cramped tiles.

Permission changes and failures were exercised with deterministic injected providers, not by revoking the user's actual permissions. Live captures across Spaces, multi-display behavior, Intel, macOS 14, and VoiceOver remain manual validation boundaries. No real windows were closed or hidden during testing.

Static analysis, whitespace checks, and the signed Debug build pass; the intentional Core Graphics fallback deprecation warning remains. Installed and relaunched **0.1.5-dev (47)** at [Swiitch Test.app](</Applications/Swiitch Test.app>). Verified its version, signature, unchanged designated signing requirement, process, and enabled keyboard event tap. Preserved and integrity-checked [build 46 backup](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build46-20260905.zip). No preferences or TCC grants were reset. No commit or push was made.

### Six-item hardening batch — installed build 48 (6 September 2026)

Completed the six remaining implementation items, with existing work preserved:

- Recover transient shortcut installation failures with bounded retries and visible status;
  route keys to a scoped recorder and reject overlapping forward/Shift-reverse bindings.
- Move AX/window metadata collection off the main actor behind a bounded worker and
  recent snapshot cache. Preserve queued input and invocation focus during cold collection;
  require the exact WindowServer ID/owner before acting on a cached target.
- Choose the display from the focused window, with largest-overlap and safe fallback rules.
- Display actual login-item status, approval requirements, and errors. Use Sparkle's
  preference-aware scheduler instead of forcing a delayed background check at launch.
- Add review-before-copy diagnostics containing only allowlisted aggregate data and status.
- Track the dependency lock; gate release numbers against local/published feeds and reject
  dirty releases; add universal Release CI/artifacts, accessible tile actions, and updated docs.

The final suite passes **258 tests, zero failed/skipped**, including a rendered AX tile
test with an external accessibility client attached. [Results](/private/tmp/swiitch-six-items.f6fiMC/FinalAXRegression.xcresult).
Universal arm64/x86_64 Release compilation, static analysis, 17 release-gate checks,
shell syntax, lock verification, and whitespace checks pass. Earlier AX harness failures
and the unattended-host skip condition are documented in the [completion checklist](/Users/pernielsentikaer/projects/swiitch/reviews/2026-09-05-improvement-plan.md).

Signed and installed **0.1.5-dev (48)** at [Swiitch Test.app](</Applications/Swiitch Test.app>),
with the same bundle identity/designated requirement and one enabled keyboard event tap.
[Build 47 backup](/Users/pernielsentikaer/projects/swiitch/build/backups/Swiitch-Test-build47-20260906.zip) is integrity-checked.
Live General/Diagnostics rendering, recording Command-Tab, rejecting the other shortcut,
and cancellation were checked. Diagnostics showed both permissions granted, keyboard ready,
login enabled, and a 34 ms metadata scan with zero timeouts; this is a single live sample,
not an end-to-end hotkey benchmark. No permission reset, actual login/update toggle,
clipboard sharing, destructive window action, commit, push, or public release occurred.

Remaining product/validation work is the real multi-display/Spaces/wake/minimum-OS matrix,
complete VoiceOver interaction, capability-aware action feedback, measured idle energy,
and localization. The historical findings below should be read with these follow-ups.

### Window-action follow-up — installed build 49 (6 September 2026)

Added capability-aware thumbnail controls, private in-panel failure explanations, scoped
window-action guards, and demand-driven bounded AX inspection. Fixed stale shortcut
validation copy and accounted for the fixed feedback header in the panel height budget.
The final suite passes **275 tests**, zero failures/skips; universal Release compilation,
static analysis, and release-gate checks pass. Build 49 is signed and installed with build
48 backed up and the same signing identity. See [the detailed follow-up](/Users/pernielsentikaer/projects/swiitch/reviews/2026-09-06-window-actions.md)
for live/synthetic verification boundaries and remaining hands-on platform testing.

## Scope and verification

- Reviewed the current working tree, including its 13 already-modified files, on branch @pnt/swiitch-quality-and-budapest, HEAD 9c0f38b. After fetching origin with pruning, the branch was 13 commits ahead of origin/main and zero behind; no merge or rebase was needed.
- Covered the app lifecycle, shortcuts, switching model, window enumeration/focusing, capture/cache, preferences, UI, tests, update handling, release script, and CI/documentation.
- All **82 existing tests passed**, with no failures or skips. Xcode static analysis passed. The existing CGWindowListCreateImage deprecation warning remains; that fallback is intentional, not a newly discovered defect.
- Shell syntax, Info.plist, appcast XML, and git diff whitespace checks passed.
- In a separate temporary project copy, **11 additional regression probes failed their expected-correct-behavior assertions**. These reproduce gaps not covered by the existing suite. The event handler was exposed internally only in that copy; events were synthetic, no event tap was installed, and focus/close actions were stubbed. No real documents were closed or manipulated by these tests.
- A read-only production-enumerator probe on this Mac found 17 apps / 19 windows: 488.8 ms for its first call, then 16.4 ms and 16.4 ms. This is a standalone cold/warm sample, not a measurement of the installed app's hotkey latency or a comprehensive performance benchmark.
- Tests ran on Apple silicon, macOS 27.0 beta (26A5425a). Intel, macOS 14, multi-display interaction, real permission revocation, and a complete live UI/VoiceOver pass were not validated.

Evidence: [baseline test result](/private/tmp/swiitch-review-20260905-baseline.xcresult), [additional probe results](/private/tmp/swiitch-project-review.JvvGKl/Probes.xcresult), [probe source](/private/tmp/swiitch-project-review.JvvGKl/SwiitchTests/ReviewProbeTests.swift). Temporary evidence may disappear when the system clears temporary files.

## P1 — fix first

### 1. A stale Close action can resolve to a different window

[WindowFocuser.swift:126](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/WindowFocuser.swift:126)

When the requested window ID is absent, the resolver accepts the only remaining Accessibility window regardless of its known ID, title, or geometry. The same resolver serves Close, Minimize, Zoom, and focus. If a tile becomes stale after its window disappears, Close can therefore press the close button on a different document. The application can still show an unsaved-changes prompt; this is not force-quitting, but the target is nevertheless wrong.

**Reproduced:** target ID 1 with only unrelated candidate ID 2 resolves to candidate 0 instead of failing safely.

**Fix:** separate focus fallback policy from window-action targeting. A known different ID must disqualify a destructive-action candidate. Permit narrowly validated metadata fallbacks only when IDs are unavailable, and refresh/remove stale entries rather than substituting another document. Audit unique-title fallback for the same mismatch.

Probe: testActionDoesNotSubstituteAnotherKnownWindowID.

### 2. Shift-reverse shortcuts are not matched correctly

[Shortcut.swift:8](/Users/pernielsentikaer/projects/swiitch/Swiitch/Hotkey/Shortcut.swift:8), [HotkeyManager.swift:130](/Users/pernielsentikaer/projects/swiitch/Swiitch/Hotkey/HotkeyManager.swift:130)

Shortcut matching requires an exact modifier set, including Shift. The subsequent code tries to interpret an additional Shift as reverse, but that event never reaches the branch. With the default Command-Tab shortcut, Command-Shift-Tab does not open Swiitch from idle; while armed, it falls through to the generic Tab handler, which advances forward. The separate “press Shift to cycle backwards” option can obscure the problem, not repair the matching logic.

**Reproduced:** reverse opening is not swallowed/armed, and reverse Tab advances from index 1 to 2 instead of 0 with standalone Shift cycling disabled.

**Fix:** resolve the configured shortcut and its reverse variant explicitly, including configurations that already use Shift, and use the resolved direction consistently.

Probes: testReverseShortcutOpensSwitcher; testReverseTabMovesBackWhileArmed.

### 3. Shortcut sessions can lose a release or wait for the wrong modifier

[HotkeyManager.swift:133](/Users/pernielsentikaer/projects/swiitch/Swiitch/Hotkey/HotkeyManager.swift:133), [HotkeyManager.swift:166](/Users/pernielsentikaer/projects/swiitch/Swiitch/Hotkey/HotkeyManager.swift:166)

Arming is dispatched asynchronously, but the release handler first checks the model's current armed state synchronously. A release delivered before the queued arm executes is discarded, leaving the picker armed afterward. Separately, release logic combines the modifiers of both configured shortcuts, so a Command-Tab session can remain open merely because Option—the other shortcut's modifier—is held.

**Reproduced:** both event orderings fail deterministic synthetic-event tests. Their frequency with real keyboard input was not measured.

**Fix:** track the active shortcut session and its own trigger modifiers immediately when accepting the opening event. Serialize session transitions, retain releases that precede model presentation, and specify multi-modifier chord behavior. Do not derive session state from the union of unrelated preferences.

Probes: testRapidPressReleaseCommitsWithoutWaitingForAnotherModifierEvent; testReleasingActiveShortcutDoesNotWaitForOtherShortcutModifier.

## P2 — reliability and interaction

### 4. Esc after a preview does not restore the original window within one app

[SwitcherModel.swift:622](/Users/pernielsentikaer/projects/swiitch/Swiitch/Model/SwitcherModel.swift:622)

Cancel saves only the original process ID and skips restoring focus when that app is still frontmost. Peeking from one Dia window to another therefore cannot be undone by Esc. The model already captures the original focused window ID, but teardown clears it before cancellation can use it.

**Reproduced:** focus calls are [window 2], not [window 2, window 1]. Restore the exact original window when it still exists, with an app-only fallback if necessary.

Probe: testCancelPeekRestoresOriginalWindowWithinSameApp.

### 5. Pinned ordering can make the first shortcut select the current app

[SwitcherModel.swift:191](/Users/pernielsentikaer/projects/swiitch/Swiitch/Model/SwitcherModel.swift:191), [WindowEnumerator.swift:112](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/WindowEnumerator.swift:112)

Apps mode always starts at index 1, assuming the frontmost app occupies index 0. Pinned apps are sorted first, invalidating that assumption. One pinned app followed by the current app makes the first invocation select the current app again.

**Reproduced:** synthetic pinned ordering selects frontmost PID 101. Determine the initial target from actual pre-switch focus and navigation policy, not a fixed index.

Probe: testPinnedOrderDoesNotMakeAppsModeSelectCurrentApp.

### 6. Ghost-window filtering can also remove real small windows

[WindowEnumerator.swift:290](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/WindowEnumerator.swift:290), [WindowEnumerator.swift:175](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/WindowEnumerator.swift:175)

The repeated-compact-window rule removes similarly sized small windows alongside a larger sibling using dimensions alone. It runs before Accessibility membership filtering, so successful AX membership cannot protect a real window already removed by the heuristic.

**Reproduced:** one 900×700 document and two visible, titled, AX-listed 300×200 notes produce only the large document. This is a synthetic false-positive case, not evidence that the user's current note windows are missing.

Use stronger window-role/behavior evidence and preserve legitimate standard windows. Keep the existing distinction between unavailable AX metadata and a confirmed empty AX list. A missing thumbnail or blank title alone must not become a reason to hide a window.

Probe: testAccessibleCompactDocumentWindowsAreNotClassifiedBySizeAlone.

### 7. Thumbnails need a freshness policy and per-window invalidation generations

[SwitcherModel.swift:950](/Users/pernielsentikaer/projects/swiitch/Swiitch/Model/SwitcherModel.swift:950), [WindowThumbnails.swift:97](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/WindowThumbnails.swift:97), [WindowThumbnails.swift:162](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/WindowThumbnails.swift:162)

Initial loading and background prewarming both request cached images without freshness. Periodic forced capture starts only while the panel remains open for two seconds. Repeated quick invocations can consequently reuse an old cached screenshot indefinitely until another refresh/invalidation/eviction occurs. This follows from the source; no elapsed-time live screenshot comparison was performed.

Separately, invalidation removes only a cached image. A capture already in flight can complete afterward and repopulate that invalidated entry.

**Reproduced:** invalidate during a blocked capture, then complete it; the next request uses its stale result instead of capturing again.

Use stale-while-revalidate with a bounded age, prioritize selected/visible windows, and invalidate both cached and pending results by window generation. Coalesce periodic refresh work and add timeouts so an unresponsive capture does not hold a batch indefinitely. Connect permission changes to stopping capture and clearing state; the cache's clear method currently has no caller.

Probe: testInvalidatedInFlightThumbnailDoesNotRepopulateCache.

### 8. Drill-in mode does not preserve selection invariants

[SwitcherModel.swift:454](/Users/pernielsentikaer/projects/swiitch/Swiitch/Model/SwitcherModel.swift:454), [SwitcherModel.swift:686](/Users/pernielsentikaer/projects/swiitch/Swiitch/Model/SwitcherModel.swift:686)

Two separate reproduced cases:

- With no matching apps after typing a filter, entering window mode still uses the unfiltered current app and clears the query. Navigation can unexpectedly reveal/select an app that was not a search result.
- Closing the selected last window of a three-window drill-in leaves selectedWindowIndex at 2 after the list shrinks to two. Commit can fall back to app focus instead of a selected window.

Require a visible selected app when drilling in. Preserve selection by window ID through reconciliation, clamp it when the target disappears, and define what happens when a drilled app has only one or zero windows left.

Probes: testNoMatchCannotDrillIntoAnInvisibleApp; testDrillInCloseKeepsAValidVisibleWindowSelection.

### 9. Clicking a tile can commit a different selection

[SwitcherView.swift:210](/Users/pernielsentikaer/projects/swiitch/Swiitch/UI/SwitcherView.swift:210), [SwitcherView.swift:437](/Users/pernielsentikaer/projects/swiitch/Swiitch/UI/SwitcherView.swift:437)

Source-confirmed path, not exercised with live mouse input: click handlers only select the clicked tile when mouseHasMoved is true, then commit unconditionally. If the pointer was already over a tile when the panel opened, clicking without moving can commit the keyboard selection instead. Apps shown above a drilled window list also cannot change selection because selectApp accepts only apps mode.

Keep the stationary-pointer guard for hover, not explicit clicks. Commit an explicit app/window ID instead of relying on a prior hover selection.

### 10. Window enumeration is still on the interaction-critical main thread

[SwitcherModel.swift:187](/Users/pernielsentikaer/projects/swiitch/Swiitch/Model/SwitcherModel.swift:187), [SwitcherModel.swift:995](/Users/pernielsentikaer/projects/swiitch/Swiitch/Model/SwitcherModel.swift:995), [AXPrivate.swift:48](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/AXPrivate.swift:48)

Opening enumerates before presentation, and four-second prewarming also enumerates on the main actor. Enumeration queries each app's Accessibility bridge without an explicit messaging timeout. A slow bridge can therefore delay UI and event processing. The standalone measurements above show a substantial first-call cost, but do not establish installed-app latency or behavior with a hung app.

Introduce bounded asynchronous metadata collection and reuse a recent snapshot for immediate opening. Revalidate the selected target before acting. Measure cold/warm invocation, many-window workloads, and AX timeouts before choosing budgets.

### 11. Fixed light/dark materials can conflict with text appearance

[Theme.swift:36](/Users/pernielsentikaer/projects/swiitch/Swiitch/Theme/Theme.swift:36), [SwitcherView.swift:541](/Users/pernielsentikaer/projects/swiitch/Swiitch/UI/SwitcherView.swift:541)

The fixed solid-dark and solid-light backgrounds do not set a corresponding foreground color scheme. Cell text still uses semantic primary/secondary colors from the application appearance. Solid-dark with Light appearance, or solid-light with Dark appearance, can therefore produce poor contrast. Minimal/Spotlight's adaptive background is already an improvement; apply a coherent foreground/background policy to the remaining materials and the preview. Confirm with a visual appearance matrix before shipping.

## Additional hardening and maintenance

- **Respect update preferences:** [AppDelegate.swift:48](/Users/pernielsentikaer/projects/swiitch/Swiitch/AppDelegate.swift:48) forces a background update check five seconds after every release-build launch without checking automaticallyChecksForUpdates. The resolved Sparkle SPUUpdater header explicitly requires respecting that setting and recommends doing a launch check immediately after starting the updater, not later. Prefer Sparkle's scheduler and expose the existing automatic-check setting in preferences.
- **Retry failed initial shortcut installation:** [HotkeyManager.swift:35](/Users/pernielsentikaer/projects/swiitch/Swiitch/Hotkey/HotkeyManager.swift:35) returns before starting health checks/wake observation if tap creation fails. With trust remaining granted, a transient initial failure has no independent retry path. Add bounded retries and visible degraded-state diagnostics; do not repeatedly prompt for permission.
- **Suspend interception during shortcut recording:** [ShortcutRecorder.swift:74](/Users/pernielsentikaer/projects/swiitch/Swiitch/UI/ShortcutRecorder.swift:74) records through a local event monitor, with no coordination to pause the global interceptor. Already-configured shortcuts can be swallowed first. Add a scoped recording session and reject conflicting bindings.
- **Show real login-item status:** [Preferences.swift:446](/Users/pernielsentikaer/projects/swiitch/Swiitch/Preferences/Preferences.swift:446) logs registration failures but leaves the stored toggle unchanged; the actual status reader is unused. Reflect enabled/approval-required/failed states instead of saved intent alone.
- **Use the focused window for display scope:** [WindowEnumerator.swift:367](/Users/pernielsentikaer/projects/swiitch/Swiitch/Windows/WindowEnumerator.swift:367) selects the first AX window, not the focused one, for “active window” screen placement. Cover two windows of one app on different displays.
- **Make release numbers enforceably monotonic:** [build_release.sh:52](/Users/pernielsentikaer/projects/swiitch/Scripts/build_release.sh:52) derives the number from total commit count. That is not monotonic across all branch, shallow-clone, and rebuild histories. Validate an explicit release number against the published appcast, and refuse accidental dirty-tree releases.
- **Make builds reproducible:** Package.resolved is ignored while Sparkle uses a version range. Track the resolved dependency lock and update it deliberately. Add unsigned Release/universal compilation and test-result artifacts to CI, alongside existing Debug tests. Test the minimum supported macOS separately when practical.
- **Refresh documentation:** README still describes app-first defaults, “-style” preset names, four tabs, and a Show Welcome button. Align it and architectural guidance with the current sidebar, all-windows default, and General permission recovery.

## Product improvements worth building

1. **An accurate layout preview.** The current [preview](/Users/pernielsentikaer/projects/swiitch/Swiitch/UI/PreferencesView.swift:662) is a fixed three-window row with 64-point thumbnails. It does not receive thumbnail size, maximum width, or grid mode. Reuse production layout calculations and offer sample window counts so Automatic versus Fit to Screen is obvious before invoking the switcher.
2. **True per-window recent history.** FocusTracker currently tracks apps by bundle ID. Track window activation within apps as well, so one invocation consistently returns to the last actual window—including another Dia window—and keep pin ordering separate from switching history.
3. **Understandable thumbnail states and private diagnostics.** Distinguish loading, unavailable capture, and missing permission instead of an unexplained blank tile. Offer a copyable diagnostics report with filtering reasons/timings/version, excluding window titles, URLs, and screenshots by default. This would make intermittent ghost-window reports much easier to investigate without collecting private content.
4. **Consistent navigation and search.** Specify row navigation versus drill-in for a multi-row app grid, support search inside a drilled app, and add visible keyboard hints. Avoid adding another toggle for each inconsistent mode.
5. **Accessible, trustworthy controls.** Add explicit accessible window labels, selected state, and keyboard-accessible window actions; verify with VoiceOver. Disable unsupported actions and provide unobtrusive failure feedback. Separate minimized-window visibility from Space filtering if users need that distinction.

## Suggested implementation sequence

1. **Safety and keyboard:** strict action targeting, reverse matching, active shortcut sessions, and permanent regression tests. These are the P1s.
2. **Correct selection and previews:** exact-window cancel restore, pinned initial selection, explicit click targets, and drill-in reconciliation.
3. **Thumbnail/filter reliability:** freshness, cancellation/invalidation, permission-aware capture, stronger evidence for filtering, and latency measurements.
4. **Product polish and release confidence:** faithful preview, contrast/accessibility, diagnostics, dependency lock, release checks, and updated documentation.

During the original audit, no application source was changed and this report was the only added repository file. Subsequent implementation is recorded in the follow-up section above.
