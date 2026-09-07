import AppKit
@testable import Swiitch
import XCTest

final class SwitcherModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "com.swiitch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.set(0, forKey: Preferences.Key.switcherShowDelayMs)
        defaults.set(false, forKey: Preferences.Key.peekOnHover)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testAppFilterUsesWindowTitlesAndKeepsAbsoluteSelection() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let apps = sampleApps()
        var focusedPID: pid_t?
        let model = makeModel(apps: apps, focusApp: { focusedPID = $0.pid })

        model.arm(reverse: false)
        XCTAssertEqual(model.selectedAppIndex, 1)

        model.appendFilter("resume")

        XCTAssertEqual(model.filteredApps.map(\.name), ["Gamma"])
        XCTAssertEqual(model.selectedAppIndex, 2, "Filtered selection must remain an absolute apps index")

        model.commit()
        XCTAssertEqual(focusedPID, 103)
        XCTAssertFalse(model.isArmed)
    }

    func testFlatWindowFilterKeepsAbsoluteSelection() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let apps = sampleApps()
        var focusedWindowID: CGWindowID?
        let model = makeModel(apps: apps, focusWindow: { focusedWindowID = $0.id })

        model.arm(reverse: false)
        XCTAssertEqual(model.selectedFlatIndex, 1)

        model.appendFilter("resume")

        XCTAssertEqual(model.filteredFlatWindows.map(\.id), [3])
        XCTAssertEqual(model.selectedFlatIndex, 2, "Filtered selection must remain an absolute window index")

        model.commit()
        XCTAssertEqual(focusedWindowID, 3)
        XCTAssertFalse(model.isArmed)
    }

    func testFlatWindowArmSkipsActualFocusedWindowWhenDiaOrderIsReversed() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let apps = [
            makeApp(
                pid: 101,
                name: "Dia",
                windows: [
                    makeWindow(id: 10, pid: 101, title: "Other Dia window"),
                    makeWindow(id: 11, pid: 101, title: "Current purple Dia window"),
                ]
            ),
            makeApp(pid: 102, name: "ChatGPT", windows: [makeWindow(id: 12, pid: 102, title: "ChatGPT")]),
        ]
        var focusedWindowID: CGWindowID?
        let model = makeModel(
            apps: apps,
            focusWindow: { focusedWindowID = $0.id },
            frontmostPID: { 101 },
            focusedWindowID: { _ in 11 }
        )

        model.arm(reverse: false)

        XCTAssertEqual(model.flatWindows.map(\.id), [11, 10, 12])
        XCTAssertEqual(model.selectedFlatIndex, 1)
        model.commit()
        XCTAssertEqual(focusedWindowID, 10)
    }

    func testDiaWindowsSwapPlacesOnSuccessiveInvocations() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let apps = diaAndChatApps()
        var focused: CGWindowID = 11
        let model = makeModel(
            apps: apps,
            focusWindow: { focused = $0.id },
            frontmostPID: { 101 },
            focusedWindowID: { _ in focused }
        )

        for expected in [CGWindowID(11), 10, 11, 10] {
            model.arm(reverse: false)
            XCTAssertEqual(model.flatWindows.first?.id, expected)
            XCTAssertNotEqual(model.flatWindows[model.selectedFlatIndex].id, focused)
            model.commit()
            XCTAssertNotEqual(focused, expected)
        }
    }

    func testMouseChangedFocusOverridesStaleWindowServerOrder() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 11, pid: 101)
        tracker.bumpWindow(id: 10, pid: 101)
        let model = makeModel(
            apps: diaAndChatApps(),
            frontmostPID: { 101 },
            focusedWindowID: { _ in 11 },
            focusTracker: tracker
        )
        model.arm(reverse: false)
        XCTAssertEqual(model.flatWindows.map(\.id), [11, 10, 12])
        XCTAssertEqual(model.flatWindows[model.selectedFlatIndex].id, 10)
        model.cancel()
    }

    func testFlatListUsesGlobalWindowHistoryNotAppGrouping() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 11, pid: 101)
        tracker.bumpWindow(id: 12, pid: 102)
        tracker.bumpWindow(id: 10, pid: 101)
        let model = makeModel(
            apps: diaAndChatApps(),
            frontmostPID: { 101 },
            focusedWindowID: { _ in 10 },
            focusTracker: tracker
        )
        model.arm(reverse: false)
        XCTAssertEqual(model.flatWindows.map(\.id), [10, 12, 11])
        XCTAssertEqual(model.flatWindows[model.selectedFlatIndex].id, 12)
        model.cancel()
    }

    func testCurrentAppModeAlsoReordersAndStaysScoped() {
        var focused: CGWindowID = 11
        let model = makeModel(
            apps: diaAndChatApps(),
            focusWindow: { focused = $0.id },
            frontmostPID: { 101 },
            focusedWindowID: { _ in focused }
        )
        model.armForCurrentApp(reverse: false)
        XCTAssertEqual(model.flatWindows.map(\.id), [11, 10])
        model.commit()
        model.armForCurrentApp(reverse: false)
        XCTAssertEqual(model.flatWindows.map(\.id), [10, 11])
        XCTAssertEqual(model.flatWindows[model.selectedFlatIndex].id, 11)
        model.cancel()
    }

    func testCommitRemembersWindowWhenNextAXReadIsUnavailable() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let tracker = FocusTracker()
        let model = makeModel(apps: diaAndChatApps(), focusTracker: tracker)
        model.arm(reverse: false)
        model.mouseHasMoved = true
        model.selectFlatWindow(at: 1)
        model.commit()
        model.arm(reverse: false)
        XCTAssertEqual(model.flatWindows.map(\.id), [11, 10, 12])
        model.cancel()
    }

    func testPreviewAndRefreshDoNotReorderOpenPickerOrRecordAVisit() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let tracker = FocusTracker()
        let model = makeModel(
            apps: diaAndChatApps(),
            focusWindow: { tracker.bumpWindow(id: $0.id, pid: $0.pid) },
            frontmostPID: { 101 },
            focusedWindowID: { _ in 11 },
            focusTracker: tracker
        )
        model.arm(reverse: false)
        model.peekCurrent()
        model.refreshAfterAppListPreferenceChange()
        XCTAssertEqual(model.flatWindows.map(\.id), [11, 10, 12])
        XCTAssertEqual(model.flatWindows[model.selectedFlatIndex].id, 10)
        XCTAssertEqual(tracker.mruWindows.map(\.id), [11])
        model.cancel()
        XCTAssertFalse(tracker.isTrackingSuspended)
    }

    func testPinnedWindowPriorityIsPreservedWithWindowHistory() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        defaults.set(["com.example.chatgpt"], forKey: Preferences.Key.pinnedBundleIDs)
        let model = makeModel(
            apps: diaAndChatApps(),
            frontmostPID: { 101 },
            focusedWindowID: { _ in 11 }
        )
        model.arm(reverse: false)
        XCTAssertEqual(model.flatWindows.map(\.id), [12, 11, 10])
        XCTAssertEqual(model.flatWindows[model.selectedFlatIndex].id, 12)
        model.cancel()
    }

    func testAppDrillInUsesAndCommitsWindowHistory() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 11, pid: 101)
        let model = makeModel(apps: diaAndChatApps(), focusTracker: tracker)
        model.arm(reverse: false)
        model.mouseHasMoved = true
        model.selectApp(at: 0)
        model.enterWindowMode()
        XCTAssertEqual(model.currentApp?.windows.map(\.id), [11, 10])
        model.selectWindow(at: 1)
        model.commit()
        XCTAssertEqual(tracker.mruWindows.map(\.id), [10, 11])
    }

    func testEmptyArmDoesNotSuspendFocusTracking() {
        let tracker = FocusTracker()
        let model = makeModel(apps: [], focusTracker: tracker)
        model.arm(reverse: false)
        XCTAssertFalse(tracker.isTrackingSuspended)
        model.armForCurrentApp(reverse: false)
        XCTAssertFalse(tracker.isTrackingSuspended)
    }

    private func diaAndChatApps() -> [AppEntry] {
        [
            makeApp(pid: 101, name: "Dia", windows: [
                makeWindow(id: 10, pid: 101, title: "Other Dia window"),
                makeWindow(id: 11, pid: 101, title: "Purple Dia window"),
            ]),
            makeApp(pid: 102, name: "ChatGPT", windows: [makeWindow(id: 12, pid: 102, title: "ChatGPT")]),
        ]
    }

    func testReverseFlatWindowArmSkipsActualFocusedWindow() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let apps = [
            makeApp(pid: 101, name: "Dia", windows: [
                makeWindow(id: 10, pid: 101, title: "Other Dia window"),
                makeWindow(id: 11, pid: 101, title: "Current Dia window"),
            ]),
            makeApp(pid: 102, name: "ChatGPT", windows: [makeWindow(id: 12, pid: 102, title: "ChatGPT")]),
        ]
        let model = makeModel(
            apps: apps,
            frontmostPID: { 101 },
            focusedWindowID: { _ in 11 }
        )

        model.arm(reverse: true)

        XCTAssertEqual(model.selectedFlatIndex, 2)
        XCTAssertNotEqual(model.flatWindows[model.selectedFlatIndex].id, 11)
    }

    func testCommitWithNoMatchesDismissesWithoutFocusingAnything() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        var focusedPIDs: [pid_t] = []
        let model = makeModel(apps: sampleApps(), focusApp: { focusedPIDs.append($0.pid) })

        model.arm(reverse: false)
        model.appendFilter("does not exist")
        XCTAssertTrue(model.filteredApps.isEmpty)

        model.commit()

        XCTAssertTrue(focusedPIDs.isEmpty)
        XCTAssertFalse(model.isArmed)
    }

    func testNoMatchCannotCloseOrHideAnInvisibleItem() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        var closedWindowIDs: [CGWindowID] = []
        var hiddenPIDs: [pid_t] = []
        let model = makeModel(
            apps: sampleApps(),
            closeWindow: {
                closedWindowIDs.append($0.id)
                return true
            },
            hideApp: {
                hiddenPIDs.append($0)
                return true
            }
        )

        model.arm(reverse: false)
        model.appendFilter("does not exist")
        model.closeSelected()
        model.hideSelected()

        XCTAssertTrue(closedWindowIDs.isEmpty)
        XCTAssertTrue(hiddenPIDs.isEmpty)
        XCTAssertEqual(model.apps.count, 3)
    }

    func testAppsModeAlwaysDrillsIntoMultipleWindowsAndClearsTheAppFilter() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let apps = [
            makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "One")]),
            makeApp(
                pid: 102,
                name: "Beta",
                windows: [
                    makeWindow(id: 2, pid: 102, title: "Two"),
                    makeWindow(id: 3, pid: 102, title: "Three"),
                ]
            ),
        ]
        let model = makeModel(apps: apps)

        model.arm(reverse: false)
        model.appendFilter("Beta")
        model.advanceRow(reverse: false)

        XCTAssertEqual(model.mode, .windowsForApp)
        XCTAssertEqual(model.filterText, "")
    }

    func testNoMatchingAppCannotDrillInOrClearSearch() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let app = makeApp(pid: 101, name: "Notes", windows: [
            makeWindow(id: 1, pid: 101, title: "One"),
            makeWindow(id: 2, pid: 101, title: "Two"),
        ])
        let model = makeModel(apps: [app])
        model.arm(reverse: false)
        defer { model.cancel() }
        model.appendFilter("no matching app")
        XCTAssertTrue(model.filteredApps.isEmpty)
        model.enterWindowMode()
        XCTAssertEqual(model.mode, .apps)
        XCTAssertEqual(model.filterText, "no matching app")
        XCTAssertTrue(model.filteredApps.isEmpty)
        model.advanceRow(reverse: false)
        XCTAssertEqual(model.mode, .apps)
        XCTAssertEqual(model.filterText, "no matching app")
    }

    func testAppsModeLoadsOnlySelectedAppThumbnailsAfterDrillIn() async throws {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let apps = [
            makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "One")]),
            makeApp(
                pid: 102,
                name: "Beta",
                windows: [
                    makeWindow(id: 2, pid: 102, title: "Two"),
                    makeWindow(id: 3, pid: 102, title: "Three"),
                ]
            ),
        ]
        let recorder = ThumbnailRecorder()
        let model = makeModel(
            apps: apps,
            thumbnails: { ids, _, _ in
                await recorder.record(ids)
                return [:]
            }
        )

        model.arm(reverse: false)
        await Task.yield()
        let beforeDrillIn = await recorder.snapshot()
        XCTAssertTrue(beforeDrillIn.isEmpty)

        model.enterWindowMode()
        for _ in 0..<50 {
            if await recorder.snapshot().count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let afterDrillIn = await recorder.snapshot()
        let batchCount = await recorder.batchCount()
        XCTAssertEqual(Set(afterDrillIn), Set([2, 3]))
        XCTAssertEqual(batchCount, 1)
    }

    func testNoMatchDrillInDoesNotStartThumbnailCapture() async throws {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let recorder = ThumbnailRecorder()
        let model = makeModel(apps: diaAndChatApps(), thumbnails: { ids, _, _ in
            await recorder.record(ids)
            return [:]
        })
        model.arm(reverse: false)
        defer { model.cancel() }
        model.appendFilter("no matching app")
        model.enterWindowMode()
        try await Task.sleep(nanoseconds: 30_000_000)
        let captured = await recorder.snapshot()
        XCTAssertTrue(captured.isEmpty)
    }

    func testDrillInWorksAgainAfterClearingNoResults() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(apps: Array(diaAndChatApps().prefix(1)))
        model.arm(reverse: false)
        defer { model.cancel() }
        model.appendFilter("no matching app")
        model.enterWindowMode()
        model.clearFilter()
        model.enterWindowMode()
        XCTAssertEqual(model.mode, .windowsForApp)
        XCTAssertEqual(model.currentApp?.name, "Dia")
    }

    func testWindowTitleSearchCanDrillIntoItsVisibleApp() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let apps = diaAndChatApps()
        let model = makeModel(apps: apps)
        model.arm(reverse: false)
        defer { model.cancel() }
        model.appendFilter(apps[0].windows[0].title)
        XCTAssertEqual(model.filteredApps.map(\.name), ["Dia"])
        model.enterWindowMode()
        XCTAssertEqual(model.mode, .windowsForApp)
        XCTAssertEqual(model.currentApp?.name, "Dia")
        XCTAssertEqual(model.filterText, "")
    }

    func testSingleWindowMatchDoesNotClearQueryOrEnterWindowMode() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(apps: sampleApps())
        model.arm(reverse: false)
        defer { model.cancel() }
        model.appendFilter("Alpha")
        model.enterWindowMode()
        XCTAssertEqual(model.mode, .apps)
        XCTAssertEqual(model.filterText, "Alpha")
    }

    func testVisibleThumbnailLoadCancelsBackgroundCaptureFirst() async throws {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let recorder = ThumbnailLifecycleRecorder()
        let model = makeModel(
            apps: sampleApps(),
            thumbnails: { ids, _, _ in
                await recorder.recordLoad(ids)
                return [:]
            },
            cancelThumbnailCaptures: {
                await recorder.recordCancellation()
            }
        )

        model.arm(reverse: false)
        for _ in 0..<50 {
            if await recorder.events().count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let events = await recorder.events()
        XCTAssertEqual(events.first, "cancel")
        XCTAssertEqual(events.dropFirst().first, "load:2,1,3", "Prioritize the highlighted window")
    }

    func testThumbnailProgressAppearsBeforeLoaderFinishes() async throws {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let capture = ProgressiveModelThumbnailCapture()
        let model = makeModel(
            apps: sampleApps(),
            thumbnails: { ids, _, onUpdate in
                await capture.load(ids: ids, onUpdate: onUpdate)
            }
        )

        model.arm(reverse: false)
        await capture.waitUntilFirstDelivery()
        for _ in 0..<50 {
            if model.thumbnails[2] != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNotNil(model.thumbnails[2], "The highlighted window should receive its image first")
        XCTAssertNil(model.thumbnails[1], "The first image should appear while the rest of the batch is still running")

        await capture.finish()
        for _ in 0..<50 {
            if model.thumbnails.count == 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(Set(model.thumbnails.keys), Set([1, 2, 3]))
    }

    func testFailedCloseKeepsTheWindowVisible() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(apps: sampleApps(), closeWindow: { _ in false })

        model.arm(reverse: false)
        let originalIDs = model.flatWindows.map(\.id)
        model.closeSelected()

        XCTAssertEqual(model.flatWindows.map(\.id), originalIDs)
    }

    func testCurrentAppWindowControlsCannotTargetAnotherApp() {
        var mutations = 0
        let model = makeModel(apps: sampleApps(),
            closeWindow: { _ in mutations += 1; return true },
            minimizeWindow: { _ in mutations += 1; return true },
            zoomWindow: { _ in mutations += 1; return true },
            frontmostPID: { 101 }, frontmostBundleID: { "test.Alpha" })
        model.armForCurrentApp(reverse: false)
        XCTAssertTrue(model.isArmed)
        XCTAssertFalse(model.closeWindow(id: 2))
        XCTAssertFalse(model.minimizeWindow(id: 2))
        XCTAssertFalse(model.zoomWindow(id: 2))
        XCTAssertEqual(mutations, 0)
    }

    func testFilteredOutWindowControlsCannotMutateHiddenTargets() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        var mutations = 0
        let model = makeModel(apps: sampleApps(),
            closeWindow: { _ in mutations += 1; return true },
            minimizeWindow: { _ in mutations += 1; return true },
            zoomWindow: { _ in mutations += 1; return true })
        model.arm(reverse: false)
        model.appendFilter("Inbox")
        XCTAssertFalse(model.closeWindow(id: 1))
        XCTAssertFalse(model.minimizeWindow(id: 1))
        XCTAssertFalse(model.zoomWindow(id: 1))
        XCTAssertEqual(mutations, 0)
        XCTAssertNil(model.actionFeedback)
    }

    func testHoverCloseTargetsRequestedWindowWithoutDismissingPicker() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        var availableApps = sampleApps()
        var closedWindowIDs: [CGWindowID] = []
        let model = makeModel(
            apps: availableApps,
            enumerate: { _ in availableApps },
            closeWindow: { target in
                closedWindowIDs.append(target.id)
                for index in availableApps.indices {
                    availableApps[index].windows.removeAll { window in window.id == target.id }
                }
                availableApps.removeAll { $0.windows.isEmpty }
                return true
            }
        )

        model.arm(reverse: false)
        XCTAssertEqual(model.selectedFlatIndex, 1)

        XCTAssertTrue(model.closeWindow(id: 1))
        XCTAssertEqual(closedWindowIDs, [1])
        XCTAssertEqual(model.flatWindows.map(\.id), [2, 3])
        XCTAssertTrue(model.isArmed)
    }

    func testAcceptedCloseKeepsWindowWhenTheAppStillReportsIt() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(apps: sampleApps(), closeWindow: { _ in true })

        model.arm(reverse: false)
        let originalIDs = model.flatWindows.map(\.id)

        XCTAssertTrue(model.closeWindow(id: 1))
        XCTAssertEqual(model.flatWindows.map(\.id), originalIDs)
        XCTAssertTrue(model.isArmed)
    }

    func testPendingCloseIsNotRepeatedOrReconciledIntoANewSession() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let availableApps = sampleApps()
        var enumerationCount = 0
        var closeCount = 0
        var scheduledReconciliation: (() -> Void)?
        let model = makeModel(
            apps: availableApps,
            enumerate: { _ in
                enumerationCount += 1
                return availableApps
            },
            closeWindow: { _ in
                closeCount += 1
                return true
            },
            scheduleCloseReconciliation: { scheduledReconciliation = $0 }
        )

        model.arm(reverse: false)
        XCTAssertTrue(model.closeWindow(id: 1))
        XCTAssertFalse(model.closeWindow(id: 1))
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(enumerationCount, 1)

        model.cancel()
        model.arm(reverse: false)
        XCTAssertEqual(enumerationCount, 2)

        scheduledReconciliation?()
        XCTAssertEqual(enumerationCount, 2)
    }

    func testHoverMinimizeAndZoomTargetRequestedWindowWithoutRemovingIt() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        var minimizedWindowIDs: [CGWindowID] = []
        var zoomedWindowIDs: [CGWindowID] = []
        let model = makeModel(
            apps: sampleApps(),
            minimizeWindow: {
                minimizedWindowIDs.append($0.id)
                return true
            },
            zoomWindow: {
                zoomedWindowIDs.append($0.id)
                return true
            }
        )

        model.arm(reverse: false)
        let originalIDs = model.flatWindows.map(\.id)

        XCTAssertTrue(model.minimizeWindow(id: 3))
        XCTAssertTrue(model.zoomWindow(id: 3))
        XCTAssertEqual(minimizedWindowIDs, [3])
        XCTAssertEqual(zoomedWindowIDs, [3])
        XCTAssertEqual(model.flatWindows.map(\.id), originalIDs)
        XCTAssertTrue(model.isArmed)
    }

    func testFailedHoverWindowActionLeavesPickerUnchanged() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(
            apps: sampleApps(),
            minimizeWindow: { _ in false },
            zoomWindow: { _ in false }
        )

        model.arm(reverse: false)
        let originalIDs = model.flatWindows.map(\.id)

        XCTAssertFalse(model.minimizeWindow(id: 1))
        XCTAssertFalse(model.zoomWindow(id: 1))
        XCTAssertEqual(model.flatWindows.map(\.id), originalIDs)
        XCTAssertTrue(model.isArmed)
    }

    func testExcludedAppsAreIdempotentAndSettingsResetKeepsOnboarding() {
        Preferences.registerDefaults(in: defaults)
        defaults.set(true, forKey: Preferences.Key.hasCompletedOnboarding)

        Preferences.excludeApp("com.example.alpha", defaults: defaults)
        Preferences.excludeApp("com.example.alpha", defaults: defaults)
        Preferences.excludeApp("com.example.beta", defaults: defaults)
        XCTAssertEqual(
            Preferences.excludedBundleIDs(in: defaults),
            ["com.example.alpha", "com.example.beta"]
        )

        Preferences.includeApp("com.example.alpha", defaults: defaults)
        XCTAssertEqual(Preferences.excludedBundleIDs(in: defaults), ["com.example.beta"])

        Preferences.resetSettings(in: defaults)
        XCTAssertTrue(Preferences.excludedBundleIDs(in: defaults).isEmpty)
        XCTAssertTrue(defaults.bool(forKey: Preferences.Key.hasCompletedOnboarding))
    }

    func testExcludedBundleIDsReachEnumerationOptions() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        Preferences.excludeApp("com.example.beta", defaults: defaults)
        let apps = sampleApps()
        var capturedOptions: EnumerateOptions?
        let model = makeModel(apps: apps, enumerate: { options in
            capturedOptions = options
            return apps.filter { !options.excludedBundleIDs.contains($0.bundleIdentifier ?? "") }
        })

        model.arm(reverse: false)

        XCTAssertEqual(capturedOptions?.excludedBundleIDs, Set(["com.example.beta"]))
        XCTAssertEqual(model.apps.map(\.name), ["Alpha", "Gamma"])
    }

    func testCancelPeekRestoresOriginalWindowWithinSameApp() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        var focusedIDs: [CGWindowID] = []
        let model = makeModel(
            apps: diaAndChatApps(),
            focusWindow: { focusedIDs.append($0.id) },
            frontmostPID: { 101 },
            focusedWindowID: { _ in 11 }
        )
        model.arm(reverse: false)
        model.peekCurrent()
        model.cancel()

        XCTAssertEqual(focusedIDs, [10, 11])
        XCTAssertFalse(model.isArmed)
    }

    func testPinnedAppsCannotMakeFirstPressSelectCurrentApp() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(apps: sampleApps(), frontmostPID: { 102 })
        model.arm(reverse: false)
        XCTAssertEqual(model.currentApp?.pid, 101)
        model.cancel()
    }

    func testReverseOpeningSkipsCurrentAppAtEndOfPinnedList() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(apps: sampleApps(), frontmostPID: { 103 })
        model.arm(reverse: true)
        XCTAssertEqual(model.currentApp?.pid, 102)
        model.cancel()
    }

    func testCancelAfterPeekRestoresTheOriginalFrontmostProcess() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        var frontmostPID: pid_t? = 999
        var restoredPIDs: [pid_t] = []
        let model = makeModel(
            apps: sampleApps(),
            focusApp: { frontmostPID = $0.pid },
            focusPID: {
                restoredPIDs.append($0)
                frontmostPID = $0
            },
            frontmostPID: { frontmostPID }
        )

        model.arm(reverse: false)
        model.peekCurrent()
        XCTAssertEqual(frontmostPID, 101, "An unlisted frontmost app should not cause the first available app to be skipped")

        model.cancel()

        XCTAssertEqual(restoredPIDs, [999])
        XCTAssertEqual(frontmostPID, 999)
        XCTAssertFalse(model.isArmed)
    }

    func testCancelWithoutPeekDoesNotChangeFocus() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        var frontmostPID: pid_t? = 999
        var restoredPIDs: [pid_t] = []
        let model = makeModel(
            apps: sampleApps(),
            focusPID: { restoredPIDs.append($0) },
            frontmostPID: { frontmostPID }
        )

        model.arm(reverse: false)
        frontmostPID = 555
        model.cancel()

        XCTAssertTrue(restoredPIDs.isEmpty)
    }

    func testCommitRepairsMRUForTheFocusedApp() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let tracker = FocusTracker()
        let model = makeModel(apps: sampleApps(), focusTracker: tracker)

        model.arm(reverse: false)
        model.commit()

        XCTAssertEqual(tracker.rank(for: "com.example.beta"), 0)
    }

    func testFitGridShrinksTilesAndUsesAdditionalColumns() {
        let automatic = SwitcherModel.gridMetrics(
            count: 8,
            maxWidth: 600,
            availableHeight: 300,
            thumbnailSize: .medium,
            fitAll: false
        )
        let fitted = SwitcherModel.gridMetrics(
            count: 8,
            maxWidth: 600,
            availableHeight: 300,
            thumbnailSize: .medium,
            fitAll: true
        )

        XCTAssertEqual(automatic.columns, 2)
        XCTAssertGreaterThan(fitted.columns, automatic.columns)
        XCTAssertLessThan(fitted.cellWidth, automatic.cellWidth)
        XCTAssertLessThan(fitted.thumbnailHeight, automatic.thumbnailHeight)
    }

    func testFitGridUsesSmallerUsableTilesBeforeOverflowingVertically() {
        let fitted = SwitcherModel.gridMetrics(
            count: 24,
            maxWidth: 600,
            availableHeight: 500,
            thumbnailSize: .medium,
            fitAll: true
        )
        let rows = Int(ceil(Double(24) / Double(fitted.columns)))
        let renderedHeight = CGFloat(rows) * (fitted.thumbnailHeight + 34)
            + CGFloat(max(0, rows - 1)) * 14

        XCTAssertEqual(fitted.columns, 6)
        XCTAssertGreaterThanOrEqual(fitted.cellWidth, 72)
        XCTAssertLessThanOrEqual(renderedHeight, 500)
    }

    func testFillGridUsesConfiguredWidthAndExpandsTiles() {
        let fitted = SwitcherModel.gridMetrics(
            count: 18,
            maxWidth: 1_200,
            availableHeight: 1_620,
            thumbnailSize: .medium,
            fitAll: true
        )

        XCTAssertEqual(fitted.columns, 4)
        XCTAssertGreaterThan(fitted.cellWidth, Preferences.ThumbnailSize.medium.cellWidth)
        XCTAssertEqual(
            CGFloat(fitted.columns) * fitted.cellWidth + CGFloat(fitted.columns - 1) * 12,
            1_200,
            accuracy: 0.001
        )
    }

    func testFillGridDiffersEvenWhenAutomaticAlreadyFits() {
        let automatic = SwitcherModel.gridMetrics(
            count: 15,
            maxWidth: 1_667,
            availableHeight: 1_084,
            thumbnailSize: .medium,
            fitAll: false
        )
        let fill = SwitcherModel.gridMetrics(
            count: 15,
            maxWidth: 1_667,
            availableHeight: 1_084,
            thumbnailSize: .medium,
            fitAll: true
        )

        XCTAssertEqual(automatic.columns, 7)
        XCTAssertEqual(fill.columns, 5)
        XCTAssertGreaterThan(fill.cellWidth, automatic.cellWidth)
        XCTAssertEqual(
            CGFloat(fill.columns) * fill.cellWidth + CGFloat(fill.columns - 1) * 12,
            1_667,
            accuracy: 0.001
        )
    }

    func testThumbnailCaptureSizePreservesAspectRatioAndCapsLongEdge() {
        let landscape = WindowThumbnails.thumbnailPixelSize(
            for: CGSize(width: 2_560, height: 1_440)
        )
        let portrait = WindowThumbnails.thumbnailPixelSize(
            for: CGSize(width: 900, height: 1_600)
        )

        XCTAssertEqual(landscape.width, 720)
        XCTAssertEqual(landscape.height, 405)
        XCTAssertEqual(portrait.width, 405)
        XCTAssertEqual(portrait.height, 720)
    }

    func testMaximumWidthPercentageCapsTheEntirePanel() {
        let limits = SwitcherPanelSizing.limits(screenWidth: 1_440, percent: 30)

        XCTAssertEqual(limits.panel, 432)
        XCTAssertEqual(limits.grid, 352)
        XCTAssertEqual(
            SwitcherPanelSizing.panelWidth(fittingWidth: 1_200, maximumWidth: limits.panel),
            432
        )
    }

    func testMinimumPanelWidthNeverOverridesConfiguredMaximum() {
        XCTAssertEqual(
            SwitcherPanelSizing.panelWidth(fittingWidth: 200, maximumWidth: 360),
            360
        )
    }

    func testPanelHeightAndOriginStayInsideTheVisibleScreen() {
        XCTAssertEqual(
            SwitcherPanelSizing.panelHeight(fittingHeight: 2_000, screenHeight: 900),
            876
        )

        let frame = SwitcherPanelSizing.clampedFrame(
            size: CGSize(width: 800, height: 876),
            preferredOrigin: CGPoint(x: -500, y: -300),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxX, 1_440)
        XCTAssertLessThanOrEqual(frame.maxY, 900)
    }

    func testRowNavigationUsesTheRenderedColumnCount() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        defaults.set(Preferences.ThumbnailSize.medium.rawValue, forKey: Preferences.Key.thumbnailSize)
        let windows = (1...6).map {
            makeWindow(id: CGWindowID($0), pid: 101, title: "Window \($0)")
        }
        let model = makeModel(apps: [makeApp(pid: 101, name: "Alpha", windows: windows)])
        model.effectiveMaxWidth = 500

        model.arm(reverse: false)
        XCTAssertEqual(model.selectedFlatIndex, 1)

        model.advanceRow(reverse: false)
        XCTAssertEqual(model.selectedFlatIndex, 3)

        model.advanceRow(reverse: true)
        XCTAssertEqual(model.selectedFlatIndex, 1)
    }

    func testExcludingTheFinalAppDismissesAnOpenSwitcher() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        var availableApps = [makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "One")])]
        let model = makeModel(apps: availableApps, enumerate: { _ in availableApps })

        model.arm(reverse: false)
        XCTAssertTrue(model.isArmed)

        availableApps = []
        model.refreshAfterAppListPreferenceChange()

        XCTAssertFalse(model.isArmed)
    }

    func testCurrentAppHotkeyShowsOnlyFrontmostAppsWindows() {
        let apps = [
            makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "Alpha")]),
            makeApp(
                pid: 102,
                name: "Beta",
                windows: [
                    makeWindow(id: 2, pid: 102, title: "Beta One"),
                    makeWindow(id: 3, pid: 102, title: "Beta Two"),
                ]
            ),
            makeApp(pid: 103, name: "Gamma", windows: [makeWindow(id: 4, pid: 103, title: "Gamma")]),
        ]
        var focusedWindowID: CGWindowID?
        let model = makeModel(
            apps: apps,
            focusWindow: { focusedWindowID = $0.id },
            frontmostPID: { 102 },
            frontmostBundleID: { "com.example.beta" }
        )

        model.armForCurrentApp(reverse: false)

        XCTAssertTrue(model.isArmed)
        XCTAssertEqual(model.mode, .currentAppWindows)
        XCTAssertEqual(model.flatWindows.map(\.id), [2, 3])
        XCTAssertEqual(Set(model.flatWindows.map(\.window.pid)), Set([102]))
        XCTAssertEqual(model.selectedFlatIndex, 1)

        model.commit()
        XCTAssertEqual(focusedWindowID, 3)
    }

    func testCurrentAppHotkeySkipsFocusedWindowWhenItIsSecond() {
        let apps = [
            makeApp(pid: 102, name: "Dia", windows: [
                makeWindow(id: 2, pid: 102, title: "Other"),
                makeWindow(id: 3, pid: 102, title: "Current"),
            ]),
        ]
        var focusedWindowID: CGWindowID?
        let model = makeModel(
            apps: apps,
            focusWindow: { focusedWindowID = $0.id },
            frontmostPID: { 102 },
            frontmostBundleID: { "com.example.dia" },
            focusedWindowID: { _ in 3 }
        )

        model.armForCurrentApp(reverse: false)

        XCTAssertEqual(model.flatWindows.map(\.id), [3, 2])
        XCTAssertEqual(model.selectedFlatIndex, 1)
        model.commit()
        XCTAssertEqual(focusedWindowID, 2)
    }

    func testCurrentAppHotkeyDoesNotFallBackWhenFrontmostAppIsMissing() {
        let model = makeModel(
            apps: sampleApps(),
            frontmostPID: { 999 },
            frontmostBundleID: { "com.example.missing" }
        )

        model.armForCurrentApp(reverse: false)

        XCTAssertFalse(model.isArmed)
        XCTAssertTrue(model.flatWindows.isEmpty)
    }

    func testCurrentAppScopeRemainsStrictAfterRefresh() {
        var availableApps = [
            makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "Alpha")]),
            makeApp(pid: 102, name: "Beta", windows: [makeWindow(id: 2, pid: 102, title: "Beta")]),
        ]
        let model = makeModel(
            apps: availableApps,
            enumerate: { _ in availableApps },
            frontmostPID: { 102 },
            frontmostBundleID: { "com.example.beta" }
        )
        model.armForCurrentApp(reverse: false)

        availableApps.append(
            makeApp(pid: 103, name: "Gamma", windows: [makeWindow(id: 3, pid: 103, title: "Gamma")])
        )
        model.refreshAfterAppListPreferenceChange()

        XCTAssertEqual(model.mode, .currentAppWindows)
        XCTAssertEqual(model.flatWindows.map(\.id), [2])
    }

    func testManyWindowModelLatencyAndScopeIntegrity() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        defaults.set(500, forKey: Preferences.Key.switcherShowDelayMs)
        let apps: [AppEntry] = (0..<25).map { appIndex in
            let pid = pid_t(1000 + appIndex)
            let windows: [WindowInfo] = (0..<20).map { index in
                .init(id: CGWindowID(appIndex * 20 + index + 1), pid: pid,
                      title: "Document \(index) — Project \(appIndex)",
                      bounds: CGRect(x: 0, y: 0, width: 1000, height: 700), isOnScreen: true)
            }
            return .init(pid: pid, bundleIdentifier: "test.app\(appIndex)", name: "App \(appIndex)",
                         icon: nil, windows: windows)
        }
        let model = makeModel(apps: apps, frontmostPID: { 1000 }, focusedWindowID: { _ in 1 })
        var opening: [Double] = []
        var searching: [Double] = []
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            model.arm(reverse: false)
            opening.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(model.flatWindows.count, 500)
            let searchStart = ProcessInfo.processInfo.systemUptime
            for letter in "Project 24" { model.appendFilter(String(letter)) }
            model.advance(reverse: false)
            searching.append((ProcessInfo.processInfo.systemUptime - searchStart) * 1000)
            XCTAssertEqual(model.filteredFlatWindows.count, 20)
            XCTAssertEqual(model.filteredFlatWindows.first?.window.pid, 1024)
            model.cancel()
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "median %.2f ms, p95 %.2f ms, maximum %.2f ms", sorted[50], sorted[94], sorted[99])
        }
        let report = "Synthetic Debug model benchmark; 25 apps / 500 windows, 100 iterations.\n"
            + "Opening: \(summary(opening))\nTyping 10 characters + cycling: \(summary(searching))\n"
            + "Excludes native discovery, drawing, captures, event-tap dispatch, and focus latency."
        let attachment = XCTAttachment(string: report)
        attachment.name = "Many-window-model-timing"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
        XCTAssertLessThan(opening.sorted()[94], 250, "Catch gross model regressions, not machine-specific timing noise")
        XCTAssertLessThan(searching.sorted()[94], 250)
    }

    func testMinimizedSettingReachesEnumerationWithoutChangingSpacePreference() {
        defaults.set(false, forKey: Preferences.Key.includeOtherSpaces)
        defaults.set(Preferences.MinimizedWindows.showLast.rawValue, forKey: Preferences.Key.minimizedWindows)
        var captured: EnumerateOptions?
        let apps = sampleApps()
        let model = makeModel(apps: apps, enumerate: { captured = $0; return apps })
        model.arm(reverse: false)
        XCTAssertEqual(captured?.includeMinimizedWindows, true)
        XCTAssertEqual(captured?.includeOtherSpaces, false)
        model.cancel()
        defaults.set(Preferences.MinimizedWindows.recentOrder.rawValue, forKey: Preferences.Key.minimizedWindows)
        model.arm(reverse: false)
        XCTAssertEqual(captured?.includeMinimizedWindows, true)
        model.cancel()
        defaults.set(Preferences.MinimizedWindows.hide.rawValue, forKey: Preferences.Key.minimizedWindows)
        model.arm(reverse: false)
        XCTAssertEqual(captured?.includeMinimizedWindows, false)
        XCTAssertEqual(captured?.includeOtherSpaces, false)
    }

    private func makeModel(
        apps: [AppEntry],
        enumerate: ((EnumerateOptions) -> [AppEntry])? = nil,
        focusApp: @escaping (AppEntry) -> Void = { _ in },
        focusWindow: @escaping (WindowInfo) -> Void = { _ in },
        closeWindow: @escaping (WindowInfo) -> Bool = { _ in true },
        minimizeWindow: @escaping (WindowInfo) -> Bool = { _ in true },
        zoomWindow: @escaping (WindowInfo) -> Bool = { _ in true },
        hideApp: @escaping (pid_t) -> Bool = { _ in true },
        focusPID: @escaping (pid_t) -> Void = { _ in },
        frontmostPID: @escaping () -> pid_t? = { nil },
        frontmostBundleID: @escaping () -> String? = { nil },
        focusedWindowID: @escaping (pid_t) -> CGWindowID? = { _ in nil },
        thumbnails: ((
            [CGWindowID],
            Bool,
            ThumbnailProgressHandler?
        ) async -> [CGWindowID: NSImage])? = nil,
        cancelThumbnailCaptures: (() async -> Void)? = nil,
        scheduleCloseReconciliation: @escaping (@escaping () -> Void) -> Void = { $0() },
        focusTracker: FocusTracker = FocusTracker()
    ) -> SwitcherModel {
        let dependencies = SwitcherModel.Dependencies(
            enumerate: { _, options in enumerate?(options) ?? apps },
            focusApp: focusApp,
            focusWindow: focusWindow,
            closeWindow: closeWindow,
            minimizeWindow: minimizeWindow,
            zoomWindow: zoomWindow,
            hideApp: hideApp,
            focusPID: focusPID,
            restoreWindowFocus: { pid, id in
                focusWindow(WindowInfo(id: id, pid: pid, title: "", bounds: .zero, isOnScreen: true))
                return true
            },
            frontmostPID: frontmostPID,
            frontmostBundleID: frontmostBundleID,
            focusedWindowID: focusedWindowID,
            thumbnails: thumbnails,
            cancelThumbnailCaptures: cancelThumbnailCaptures,
            scheduleCloseReconciliation: scheduleCloseReconciliation
        )
        return SwitcherModel(
            focusTracker: focusTracker,
            defaults: defaults,
            dependencies: dependencies
        )
    }

    private func sampleApps() -> [AppEntry] {
        [
            makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "Dashboard")]),
            makeApp(pid: 102, name: "Beta", windows: [makeWindow(id: 2, pid: 102, title: "Inbox")]),
            makeApp(pid: 103, name: "Gamma", windows: [makeWindow(id: 3, pid: 103, title: "Résumé 2026")]),
        ]
    }

    private func makeApp(pid: pid_t, name: String, windows: [WindowInfo]) -> AppEntry {
        AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.\(name.lowercased())",
            name: name,
            icon: nil,
            windows: windows
        )
    }

    private func makeWindow(id: CGWindowID, pid: pid_t, title: String) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            title: title,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true
        )
    }
}

private actor ThumbnailRecorder {
    private var batches: [[CGWindowID]] = []

    func record(_ ids: [CGWindowID]) {
        batches.append(ids)
    }

    func snapshot() -> [CGWindowID] {
        batches.flatMap { $0 }
    }

    func batchCount() -> Int {
        batches.count
    }
}

private actor ThumbnailLifecycleRecorder {
    private var recordedEvents: [String] = []

    func recordCancellation() {
        recordedEvents.append("cancel")
    }

    func recordLoad(_ ids: [CGWindowID]) {
        recordedEvents.append("load:\(ids.map(String.init).joined(separator: ","))")
    }

    func events() -> [String] {
        recordedEvents
    }
}

private actor ProgressiveModelThumbnailCapture {
    private var didDeliverFirst = false
    private var mayFinish = false
    private var firstDeliveryWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func load(
        ids: [CGWindowID],
        onUpdate: ThumbnailProgressHandler?
    ) async -> [CGWindowID: NSImage] {
        guard let first = ids.first else { return [:] }
        let image = NSImage(size: NSSize(width: 32, height: 24))
        await onUpdate?(first, image)
        didDeliverFirst = true
        firstDeliveryWaiters.forEach { $0.resume() }
        firstDeliveryWaiters.removeAll()

        if !mayFinish {
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
            }
        }
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, image) })
    }

    func waitUntilFirstDelivery() async {
        if didDeliverFirst { return }
        await withCheckedContinuation { continuation in
            firstDeliveryWaiters.append(continuation)
        }
    }

    func finish() {
        mayFinish = true
        finishWaiters.forEach { $0.resume() }
        finishWaiters.removeAll()
    }
}
