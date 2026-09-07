import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class SwitcherInteractionTests: XCTestCase {
    func testCommittedPreviewRecordsRealVisitInEveryMode() {
        for mode in [SwitcherModel.Mode.apps, .flatWindows, .windowsForApp, .currentAppWindows] {
            let fixture = Fixture(displayMode: mode == .apps || mode == .windowsForApp ? .apps : .windows)
            for bundle in ["beta", "gamma", "alpha"] { fixture.tracker.bump("com.example.\(bundle)") }
            let before = fixture.tracker.mruByBundle
            if mode == .currentAppWindows { fixture.model.armForCurrentApp(reverse: false) }
            else { fixture.model.arm(reverse: false) }
            if mode == .windowsForApp { fixture.model.enterWindowMode() }
            if mode == .flatWindows { fixture.model.appendFilter("Beta 21") }
            fixture.model.peekCurrent()
            let pid = fixture.state.frontmostPID!
            let bundle = fixture.state.apps.first { $0.pid == pid }!.bundleIdentifier!
            let id = fixture.state.focusedByPID[pid]!
            fixture.tracker.bump(bundle)
            fixture.tracker.bumpWindow(id: id, pid: pid)
            XCTAssertEqual(fixture.tracker.mruByBundle, before, "Preview: \(mode)")
            fixture.model.commit()
            XCTAssertFalse(fixture.tracker.isTrackingSuspended)
            XCTAssertEqual(fixture.tracker.mruByBundle, [bundle] + before.filter { $0 != bundle }, "Commit: \(mode)")
            XCTAssertEqual(fixture.tracker.mruWindows.first, .init(pid: pid, id: id))
        }
    }

    func testCancelledAppPreviewPreservesAppAndWindowHistory() {
        for emptyCommit in [false, true] {
            let fixture = Fixture(displayMode: .apps)
            for bundle in ["beta", "gamma", "alpha"] { fixture.tracker.bump("com.example.\(bundle)") }
            fixture.tracker.bumpWindow(id: 31, pid: 103)
            fixture.tracker.bumpWindow(id: 11, pid: 101)
            let appsBefore = fixture.tracker.mruByBundle
            let windowsBefore = fixture.tracker.mruWindows
            fixture.model.arm(reverse: false)
            fixture.model.peekCurrent()
            // Simulate the same history calls made by app/window activation observers.
            fixture.tracker.bump("com.example.beta")
            fixture.tracker.bumpWindow(id: 21, pid: 102)
            if emptyCommit {
                fixture.model.appendFilter("no matching document exists")
                fixture.model.commit()
            } else {
                fixture.model.cancel()
            }
            XCTAssertEqual(fixture.state.restoreRequests, [.init(pid: 101, id: 11)])
            XCTAssertEqual(fixture.tracker.mruByBundle, appsBefore)
            XCTAssertEqual(fixture.tracker.mruWindows, windowsBefore)
        }
    }

    func testShowLastKeepsRecentOrderWithinNormalAndMinimizedGroups() {
        let fixture = Fixture()
        fixture.state.setMinimized(true, id: 12)
        fixture.state.setMinimized(true, id: 21)
        fixture.tracker.bumpWindow(id: 21, pid: 102)
        fixture.tracker.bumpWindow(id: 12, pid: 101)
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), [11, 22, 31, 12, 21])
        XCTAssertEqual(fixture.model.flatWindows[fixture.model.selectedFlatIndex].id, 22)
    }

    func testRecentOrderLeavesMinimizedWindowsInHistoryPosition() {
        let fixture = Fixture()
        fixture.defaults.set(Preferences.MinimizedWindows.recentOrder.rawValue, forKey: Preferences.Key.minimizedWindows)
        fixture.state.setMinimized(true, id: 12)
        fixture.tracker.bumpWindow(id: 12, pid: 101)
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), [11, 12, 21, 22, 31])
        XCTAssertEqual(fixture.model.flatWindows[fixture.model.selectedFlatIndex].id, 12)
    }

    func testMinimizedOrderingKeepsAppsGroupedAndDoesNotDemoteMixedApp() {
        let fixture = Fixture(displayMode: .apps)
        fixture.state.setMinimized(true, id: 11)
        fixture.state.focusedByPID[101] = 12
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.apps.map(\.pid), [101, 102, 103])
        XCTAssertEqual(fixture.model.apps[0].windows.map(\.id), [12, 11])
        fixture.model.chooseWindows(of: 101)
        XCTAssertEqual(fixture.model.filteredAppWindows.map(\.id), [12, 11])
        fixture.model.commitWindow(id: 11)
        XCTAssertEqual(fixture.state.focusedWindows, [11], "Minimized windows remain selectable by exact identity")
    }

    func testCurrentAppScopeSortsMinimizedLastWithoutAddingOtherApps() {
        let fixture = Fixture()
        fixture.state.setMinimized(true, id: 11)
        fixture.state.focusedByPID[101] = 12
        fixture.model.armForCurrentApp(reverse: false)
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), [12, 11])
        fixture.model.commit()
        XCTAssertEqual(fixture.state.focusedWindows, [11])
    }

    func testDontShowFiltersMinimizedWindowsAndDropsOnlyEmptyApps() {
        let fixture = Fixture()
        fixture.defaults.set(Preferences.MinimizedWindows.hide.rawValue, forKey: Preferences.Key.minimizedWindows)
        for id: CGWindowID in [12, 21, 22] { fixture.state.setMinimized(true, id: id) }
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), [11, 31])
        XCTAssertEqual(fixture.model.apps.map(\.pid), [101, 103])
        fixture.model.cancel()
        fixture.state.frontmostPID = 102
        fixture.model.armForCurrentApp(reverse: false)
        XCTAssertFalse(fixture.model.isArmed, "An excluded current app must not fall back to another app")
    }

    func testMinimizationAndRestoreUpdateStateWithoutMovingTilesUntilNextInvocation() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.mouseHasMoved = true
        fixture.model.selectFlatWindow(at: 4)
        let original = fixture.model.flatWindows.map(\.id)
        fixture.state.setMinimized(true, id: 12)
        fixture.model.refreshAfterAppListPreferenceChange()
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), original)
        XCTAssertEqual(fixture.model.flatWindows.first { $0.id == 12 }?.window.isMinimized, true)
        XCTAssertEqual(fixture.model.flatWindows[fixture.model.selectedFlatIndex].id, 31)
        fixture.model.cancel()
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), [11, 21, 22, 31, 12])
        fixture.state.setMinimized(false, id: 12)
        fixture.model.refreshAfterAppListPreferenceChange()
        XCTAssertEqual(fixture.model.flatWindows.last?.id, 12)
        XCTAssertEqual(fixture.model.flatWindows.last?.window.isMinimized, false)
        fixture.model.cancel()
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), original)
    }

    func testMinimizedSearchResultRemainsSelectableWithoutChangingOrder() {
        let fixture = Fixture()
        fixture.state.setMinimized(true, id: 12)
        fixture.model.arm(reverse: false)
        let original = fixture.model.flatWindows.map(\.id)
        fixture.model.appendFilter("Alpha")
        XCTAssertEqual(fixture.model.filteredFlatWindows.map(\.id), [11, 12])
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), original)
        fixture.model.commitWindow(id: 12)
        XCTAssertEqual(fixture.state.focusedWindows, [12])
        XCTAssertEqual(fixture.tracker.mruWindows.first?.id, 12)
    }

    func testCommittingEmptySearchAfterPeekRestoresOriginalInEveryMode() {
        for mode in [SwitcherModel.Mode.apps, .flatWindows, .currentAppWindows, .windowsForApp] {
            let fixture = Fixture(displayMode: mode == .apps || mode == .windowsForApp ? .apps : .windows)
            if mode == .currentAppWindows { fixture.model.armForCurrentApp(reverse: false) }
            else { fixture.model.arm(reverse: false) }
            if mode == .windowsForApp { fixture.model.enterWindowMode() }
            fixture.model.peekCurrent()
            fixture.model.appendFilter("no matching document exists")
            fixture.model.commit()
            XCTAssertFalse(fixture.model.isArmed)
            XCTAssertEqual(fixture.state.restoreRequests, [.init(pid: 101, id: 11)], "\(mode)")
            XCTAssertEqual(fixture.state.frontmostPID, 101, "\(mode)")
            XCTAssertEqual(fixture.state.focusedByPID[101], 11, "\(mode)")
            XCTAssertFalse(fixture.tracker.isTrackingSuspended)
        }
    }

    func testCommittingEmptySearchWithoutPeekDoesNotChangeFocus() {
        for mode in [SwitcherModel.Mode.apps, .flatWindows, .currentAppWindows, .windowsForApp] {
            let fixture = Fixture(displayMode: mode == .apps || mode == .windowsForApp ? .apps : .windows)
            if mode == .currentAppWindows { fixture.model.armForCurrentApp(reverse: false) }
            else { fixture.model.arm(reverse: false) }
            if mode == .windowsForApp { fixture.model.enterWindowMode() }
            let history = fixture.tracker.mruWindows
            fixture.model.appendFilter("no matching document exists")
            fixture.model.commit()
            XCTAssertFalse(fixture.model.isArmed)
            XCTAssertTrue(fixture.state.restoreRequests.isEmpty)
            XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
            XCTAssertTrue(fixture.state.focusedApps.isEmpty)
            XCTAssertTrue(fixture.state.fallbackPIDs.isEmpty)
            XCTAssertEqual(fixture.tracker.mruWindows, history)
        }
    }

    func testEmptyCommitAfterCrossAppPeekKeepsOriginalAppFallback() {
        for missingID in [false, true] {
            let fixture = Fixture(displayMode: .apps)
            if missingID { fixture.state.focusedByPID[101] = nil }
            fixture.model.arm(reverse: false)
            fixture.model.peekCurrent()
            fixture.state.canRestore = false
            fixture.model.appendFilter("no matching document exists")
            fixture.model.commit()
            XCTAssertEqual(fixture.state.restoreRequests.count, missingID ? 0 : 1)
            XCTAssertEqual(fixture.state.fallbackPIDs, [101])
            XCTAssertEqual(fixture.state.frontmostPID, 101)
            XCTAssertTrue(fixture.state.focusedWindows.isEmpty, "Never substitute an arbitrary sibling")
        }
    }

    func testMatchingCommitAfterPeekStillSelectsResultInsteadOfRestoringOriginal() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.peekCurrent()
        fixture.model.appendFilter("Beta 21")
        fixture.model.commit()
        XCTAssertEqual(fixture.state.focusedWindows, [12, 21])
        XCTAssertTrue(fixture.state.restoreRequests.isEmpty)
        XCTAssertEqual(fixture.tracker.mruWindows.first, .init(pid: 102, id: 21))
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testAccessibleDrillInTargetsExactAppWithoutHover() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        XCTAssertFalse(fixture.model.mouseHasMoved)
        fixture.model.chooseWindows(of: 101)
        XCTAssertEqual(fixture.model.mode, .windowsForApp)
        XCTAssertEqual(fixture.model.currentApp?.pid, 101)
        XCTAssertTrue(fixture.state.focusedApps.isEmpty)
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
    }

    func testAccessibleDrillInRejectsFilteredOrUnknownApp() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("Gamma")
        fixture.model.chooseWindows(of: 101)
        fixture.model.chooseWindows(of: 999)
        XCTAssertEqual(fixture.model.mode, .apps)
        XCTAssertEqual(fixture.model.filterText, "Gamma")
    }

    func testStationaryClickCommitsExactFlatWindowAndUpdatesHistory() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        XCTAssertFalse(fixture.model.mouseHasMoved)
        XCTAssertEqual(fixture.model.flatWindows[fixture.model.selectedFlatIndex].id, 12)
        fixture.model.commitWindow(id: 31)
        XCTAssertEqual(fixture.state.focusedWindows, [31])
        XCTAssertEqual(fixture.tracker.mruWindows.first?.id, 31)
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testStationaryClickCommitsExactApp() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.commitApp(id: 103)
        XCTAssertEqual(fixture.state.focusedApps, [103])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testStationaryClickCommitsExactDrilledWindow() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        XCTAssertEqual(fixture.model.mode, .windowsForApp)
        fixture.model.commitWindow(id: 22)
        XCTAssertEqual(fixture.state.focusedWindows, [22])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testClickingAppStripWhileDrilledInCommitsThatApp() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        fixture.model.commitApp(id: 103)
        XCTAssertEqual(fixture.state.focusedApps, [103])
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
    }

    func testFilteredOutAndUnknownWindowClicksCannotCommitOtherSelection() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("Gamma")
        fixture.model.commitWindow(id: 11)
        fixture.model.commitWindow(id: 999)
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
        fixture.model.commitWindow(id: 31)
        XCTAssertEqual(fixture.state.focusedWindows, [31])
    }

    func testFilteredOutAndUnknownAppClicksCannotCommitOtherSelection() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("Gamma")
        fixture.model.commitApp(id: 101)
        fixture.model.commitApp(id: 999)
        XCTAssertTrue(fixture.state.focusedApps.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
        fixture.model.commitApp(id: 103)
        XCTAssertEqual(fixture.state.focusedApps, [103])
    }

    func testCurrentAppClickCannotEscapeItsScope() {
        let fixture = Fixture()
        fixture.model.armForCurrentApp(reverse: false)
        fixture.model.commitWindow(id: 21)
        fixture.model.commitApp(id: 102)
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
        XCTAssertTrue(fixture.state.focusedApps.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
        fixture.model.commitWindow(id: 12)
        XCTAssertEqual(fixture.state.focusedWindows, [12])
    }

    func testDrilledWindowClickCannotTargetAnotherApp() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        fixture.model.commitWindow(id: 11)
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testStaleWindowClickAfterRefreshIsIgnored() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.state.apps.removeLast()
        fixture.model.refreshAfterAppListPreferenceChange()
        fixture.model.commitWindow(id: 31)
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testStaleAppClickAfterRefreshIsIgnored() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.state.apps.removeLast()
        fixture.model.refreshAfterAppListPreferenceChange()
        fixture.model.commitApp(id: 103)
        XCTAssertTrue(fixture.state.focusedApps.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testClickIdentitySurvivesListReordering() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.state.apps.reverse()
        fixture.model.refreshAfterAppListPreferenceChange()
        fixture.model.commitWindow(id: 21)
        XCTAssertEqual(fixture.state.focusedWindows, [21])
    }

    func testHoverStillRequiresPointerMovement() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        let selected = fixture.model.selectedFlatIndex
        fixture.model.selectFlatWindow(at: 4)
        XCTAssertEqual(fixture.model.selectedFlatIndex, selected)
        fixture.model.mouseHasMoved = true
        fixture.model.selectFlatWindow(at: 4)
        XCTAssertEqual(fixture.model.selectedFlatIndex, 4)
    }

    func testClicksAfterDismissalDoNothing() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.cancel()
        fixture.model.commitWindow(id: 31)
        fixture.model.commitApp(id: 103)
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
        XCTAssertTrue(fixture.state.focusedApps.isEmpty)
    }

    func testCancelAfterCrossAppPeekRestoresWindowAndHistory() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.advance(reverse: false)
        fixture.model.peekCurrent()
        XCTAssertEqual(fixture.state.frontmostPID, 102)
        fixture.tracker.bump("com.example.beta")
        fixture.model.cancel()
        XCTAssertEqual(fixture.state.restoreRequests, [.init(pid: 101, id: 11)])
        XCTAssertEqual(fixture.state.frontmostPID, 101)
        XCTAssertEqual(fixture.state.focusedByPID[101], 11)
        XCTAssertEqual(fixture.tracker.mruWindows.first, .init(pid: 101, id: 11))
        XCTAssertEqual(fixture.tracker.rank(for: "com.example.alpha"), 0)
        XCTAssertTrue(fixture.state.fallbackPIDs.isEmpty)
        XCTAssertFalse(fixture.tracker.isTrackingSuspended)
    }

    func testCancelCurrentAppPeekRestoresOriginalSibling() {
        let fixture = Fixture()
        fixture.model.armForCurrentApp(reverse: false)
        fixture.model.peekCurrent()
        XCTAssertEqual(fixture.state.focusedByPID[101], 12)
        fixture.model.cancel()
        XCTAssertEqual(fixture.state.focusedByPID[101], 11)
        XCTAssertEqual(fixture.state.restoreRequests, [.init(pid: 101, id: 11)])
    }

    func testCancelRestoresOriginalEvenWhenExcludedFromPicker() {
        let fixture = Fixture()
        fixture.defaults.set(["com.example.alpha"], forKey: Preferences.Key.excludedBundleIDs)
        fixture.model.arm(reverse: false)
        XCTAssertFalse(fixture.model.apps.contains(where: { $0.pid == 101 }))
        fixture.model.peekCurrent()
        fixture.model.cancel()
        XCTAssertEqual(fixture.state.frontmostPID, 101)
        XCTAssertEqual(fixture.state.restoreRequests, [.init(pid: 101, id: 11)])
    }

    func testClosedOriginalDoesNotRaiseAnArbitrarySibling() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.peekCurrent()
        fixture.state.apps[0].windows.removeFirst()
        fixture.model.cancel()
        XCTAssertEqual(fixture.state.focusedByPID[101], 12)
        XCTAssertEqual(fixture.state.restoreRequests, [.init(pid: 101, id: 11)])
        XCTAssertTrue(fixture.state.fallbackPIDs.isEmpty)
        XCTAssertEqual(fixture.state.focusedWindows, [12])
    }

    func testClosedOriginalAfterCrossAppPeekFallsBackToOriginalApp() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.advance(reverse: false)
        fixture.model.peekCurrent()
        fixture.state.apps[0].windows.removeFirst()
        fixture.model.cancel()
        XCTAssertEqual(fixture.state.fallbackPIDs, [101])
        XCTAssertEqual(fixture.state.frontmostPID, 101)
    }

    func testMissingOriginalWindowIDUsesAppFallback() {
        let fixture = Fixture()
        fixture.state.focusedByPID[101] = nil
        fixture.model.arm(reverse: false)
        fixture.model.advance(reverse: false)
        fixture.model.peekCurrent()
        fixture.model.cancel()
        XCTAssertTrue(fixture.state.restoreRequests.isEmpty)
        XCTAssertEqual(fixture.state.fallbackPIDs, [101])
    }

    func testFailedRestorationUsesAppFallback() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.advance(reverse: false)
        fixture.model.peekCurrent()
        fixture.state.canRestore = false
        fixture.model.cancel()
        XCTAssertEqual(fixture.state.fallbackPIDs, [101])
        XCTAssertEqual(fixture.state.restoreRequests.count, 1)
    }

    func testAppOpeningSkipsCurrentPIDInEveryPresentationPosition() {
        let orders: [[Int]] = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        for order in orders {
            for current: pid_t in [101, 102, 103] {
                for reverse in [false, true] {
                    let fixture = Fixture(displayMode: .apps)
                    let original = fixture.state.apps
                    fixture.state.apps = order.map { original[$0] }
                    fixture.state.frontmostPID = current
                    fixture.model.arm(reverse: reverse)
                    let alternatives = fixture.state.apps.filter { $0.pid != current }
                    XCTAssertEqual(fixture.model.currentApp?.pid, reverse ? alternatives.last?.pid : alternatives.first?.pid)
                }
            }
        }
    }

    func testAppOpeningUsesBundleOnlyWhenPIDIsUnavailable() {
        let fixture = Fixture(displayMode: .apps)
        fixture.state.frontmostPID = nil
        fixture.state.bundleOverride = "com.example.beta"
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.currentApp?.pid, 101)
    }

    func testAppOpeningPrefersPIDOverConflictingBundleReport() {
        let fixture = Fixture(displayMode: .apps)
        fixture.state.frontmostPID = 102
        fixture.state.bundleOverride = "com.example.alpha"
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.currentApp?.pid, 101)
    }

    func testAppOpeningWithSingleCurrentAppStillSelectsIt() {
        let fixture = Fixture(displayMode: .apps)
        fixture.state.apps = [fixture.state.apps[0]]
        fixture.model.arm(reverse: true)
        XCTAssertEqual(fixture.model.currentApp?.pid, 101)
        XCTAssertEqual(fixture.model.selectedAppIndex, 0)
    }

    func testDrillInSearchFiltersWindowsWithoutFilteringAppStrip() {
        let fixture = Fixture(displayMode: .apps)
        fixture.state.apps[1].windows[1] = WindowInfo(id: 22, pid: 102, title: "Résumé", bounds: .zero, isOnScreen: true)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        fixture.model.appendFilter("RESUME")
        XCTAssertEqual(fixture.model.filteredAppWindows.map(\.id), [22])
        XCTAssertEqual(fixture.model.filteredApps.count, 3)
        XCTAssertEqual(fixture.model.selectedWindowIndex, 1)
        fixture.model.commit()
        XCTAssertEqual(fixture.state.focusedWindows, [22])
    }

    func testMultiwordSearchCombinesAppAndTitleInEveryWindowMode() {
        for mode in [SwitcherModel.Mode.flatWindows, .currentAppWindows, .windowsForApp] {
            let fixture = Fixture(displayMode: mode == .windowsForApp ? .apps : .windows)
            configureSearchWindows(fixture)
            if mode == .currentAppWindows {
                fixture.state.frontmostPID = 102
                fixture.model.armForCurrentApp(reverse: false)
            } else {
                fixture.model.arm(reverse: false)
                if mode == .windowsForApp { fixture.model.chooseWindows(of: 102) }
            }
            for query in ["dia calendar", "CALENDAR DIA", "  dia\t calendar \n"] {
                fixture.model.clearFilter()
                fixture.model.appendFilter(query)
                let ids = mode == .windowsForApp
                    ? fixture.model.filteredAppWindows.map(\.id) : fixture.model.filteredFlatWindows.map(\.id)
                XCTAssertEqual(ids, [21], "\(mode): \(query)")
            }
            fixture.model.commit()
            XCTAssertEqual(fixture.state.focusedWindows, [21])
        }
    }

    func testMultiwordAppSearchRequiresAllWordsWithinOneWindowAndApp() {
        let fixture = Fixture(displayMode: .apps)
        configureSearchWindows(fixture)
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("dia calendar")
        XCTAssertEqual(fixture.model.filteredApps.map(\.pid), [102])
        fixture.model.appendFilter(" resume")
        XCTAssertTrue(fixture.model.filteredApps.isEmpty, "Calendar and Resume belong to different windows")
        fixture.model.commit()
        XCTAssertTrue(fixture.state.focusedApps.isEmpty)
    }

    func testMultiwordSearchKeepsAccentInsensitiveMatchingAndLiteralPunctuation() {
        let fixture = Fixture()
        configureSearchWindows(fixture)
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("DIA RESUME [Q1]")
        XCTAssertEqual(fixture.model.filteredFlatWindows.map(\.id), [22])
        fixture.model.appendFilter(" missing")
        XCTAssertTrue(fixture.model.filteredFlatWindows.isEmpty)
        fixture.model.commitWindow(id: 22)
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testWhitespaceOnlyQueryAndSearchDoNotChangeRecentWindowOrder() {
        let fixture = Fixture()
        configureSearchWindows(fixture)
        fixture.tracker.bumpWindow(id: 22, pid: 102)
        fixture.model.arm(reverse: false)
        let original = fixture.model.filteredFlatWindows.map(\.id)
        fixture.model.appendFilter(" \t\n ")
        XCTAssertEqual(fixture.model.filteredFlatWindows.map(\.id), original)
        fixture.model.appendFilter("dia")
        let expected = original.filter { $0 == 21 || $0 == 22 }
        XCTAssertEqual(fixture.model.filteredFlatWindows.map(\.id), expected)
        fixture.model.clearFilter()
        XCTAssertEqual(fixture.model.filteredFlatWindows.map(\.id), original)
    }

    func testMultiwordAppNameStillFindsAnAppWithoutWindows() {
        let fixture = Fixture(displayMode: .apps)
        fixture.state.apps[1] = AppEntry(pid: 102, bundleIdentifier: "com.example.beta",
            name: "Visual Studio Code", icon: nil, windows: [])
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("code visual")
        XCTAssertEqual(fixture.model.filteredApps.map(\.pid), [102])
    }

    private func configureSearchWindows(_ fixture: Fixture) {
        fixture.state.apps[1] = AppEntry(pid: 102, bundleIdentifier: "com.example.beta", name: "Dia", icon: nil,
            windows: [
                WindowInfo(id: 21, pid: 102, title: "Calendar — Team", bounds: .zero, isOnScreen: true),
                WindowInfo(id: 22, pid: 102, title: "Résumé [Q1]", bounds: .zero, isOnScreen: true),
            ])
    }

    func testDrillInSearchNavigationAndBackspaceUseVisibleWindowIdentities() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        fixture.model.appendFilter("22")
        fixture.model.advance(reverse: false)
        fixture.model.advance(reverse: true)
        XCTAssertEqual(fixture.model.selectedVisibleAppWindow?.id, 22)
        fixture.model.backspaceFilter()
        XCTAssertEqual(fixture.model.filteredAppWindows.map(\.id), [21, 22])
        XCTAssertEqual(fixture.model.selectedVisibleAppWindow?.id, 22)
        fixture.model.advance(reverse: false)
        XCTAssertEqual(fixture.model.selectedVisibleAppWindow?.id, 21)
        fixture.model.clearFilter()
        XCTAssertEqual(fixture.model.selectedVisibleAppWindow?.id, 21)
    }

    func testDrillInEmptySearchCannotFocusHideOrActOnAnInvisibleWindow() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        fixture.model.appendFilter("no result")
        fixture.model.peekCurrent()
        fixture.model.closeSelected()
        fixture.model.hideSelected()
        XCTAssertFalse(fixture.model.closeWindow(id: 21))
        XCTAssertFalse(fixture.model.minimizeWindow(id: 21))
        XCTAssertFalse(fixture.model.zoomWindow(id: 21))
        fixture.model.mouseHasMoved = true
        fixture.model.selectWindow(at: 1)
        fixture.model.commitWindow(id: 22)
        XCTAssertTrue(fixture.model.isArmed)
        XCTAssertNil(fixture.model.selectedVisibleAppWindow)
        XCTAssertTrue(fixture.state.actions.isEmpty)
        fixture.model.commit()
        XCTAssertTrue(fixture.state.focusedWindows.isEmpty)
        XCTAssertTrue(fixture.state.focusedApps.isEmpty)
    }

    func testExitingDrillInRestoresAppQueryInsteadOfLeakingWindowQuery() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("Beta")
        fixture.model.enterWindowMode()
        fixture.model.appendFilter("22")
        fixture.model.advanceRow(reverse: true)
        XCTAssertEqual(fixture.model.mode, .apps)
        XCTAssertEqual(fixture.model.filterText, "Beta")
        XCTAssertEqual(fixture.model.filteredApps.map(\.pid), [102])
        fixture.model.enterWindowMode()
        XCTAssertEqual(fixture.model.filterText, "")
        fixture.model.appendFilter("no result")
        fixture.model.advanceRow(reverse: true)
        XCTAssertEqual(fixture.model.mode, .apps)
        XCTAssertEqual(fixture.model.filterText, "Beta")
    }

    func testDrillInRefreshPreservesSelectionByIDAndDoesNotJumpToAnotherApp() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        fixture.model.appendFilter("22")
        fixture.state.apps[1].windows.reverse()
        fixture.model.refreshAfterAppListPreferenceChange()
        XCTAssertEqual(fixture.model.selectedVisibleAppWindow?.id, 22)
        XCTAssertEqual(fixture.model.selectedWindowIndex, 0)
        fixture.state.apps.removeAll { $0.pid == 102 }
        fixture.model.refreshAfterAppListPreferenceChange()
        XCTAssertEqual(fixture.model.mode, .apps)
        XCTAssertEqual(fixture.model.filterText, "")
    }

    func testAppStripClickStillCommitsExplicitAppDuringWindowSearch() {
        let fixture = Fixture(displayMode: .apps)
        fixture.model.arm(reverse: false)
        fixture.model.enterWindowMode()
        fixture.model.appendFilter("22")
        fixture.model.commitApp(id: 103)
        XCTAssertEqual(fixture.state.focusedApps, [103])
    }

    private final class State {
        var apps: [AppEntry] = [
            app(101, "Alpha", [11, 12]), app(102, "Beta", [21, 22]), app(103, "Gamma", [31]),
        ]
        var frontmostPID: pid_t? = 101
        var focusedByPID: [pid_t: CGWindowID] = [101: 11, 102: 21, 103: 31]
        var bundleOverride: String?
        var focusedWindows: [CGWindowID] = []
        var focusedApps: [pid_t] = []
        var restoreRequests: [FocusTracker.WindowKey] = []
        var fallbackPIDs: [pid_t] = []
        var canRestore = true
        var actions: [String] = []

        func setMinimized(_ minimized: Bool, id: CGWindowID) {
            for appIndex in apps.indices {
                if let index = apps[appIndex].windows.firstIndex(where: { $0.id == id }) {
                    apps[appIndex].windows[index].isMinimized = minimized
                }
            }
        }

        private static func app(_ pid: pid_t, _ name: String, _ ids: [CGWindowID]) -> AppEntry {
            AppEntry(pid: pid, bundleIdentifier: "com.example.\(name.lowercased())", name: name, icon: nil,
                     windows: ids.map { WindowInfo(id: $0, pid: pid, title: "\(name) \($0)", bounds: .zero, isOnScreen: true) })
        }
    }

    private final class Fixture {
        let suite = "com.swiitch.interaction-tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let state = State()
        let tracker = FocusTracker()
        let model: SwitcherModel

        init(displayMode: Preferences.DisplayMode = .windows) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(displayMode.rawValue, forKey: Preferences.Key.displayMode)
            defaults.set(0, forKey: Preferences.Key.switcherShowDelayMs)
            defaults.set(false, forKey: Preferences.Key.peekOnHover)
            defaults.set([], forKey: Preferences.Key.pinnedBundleIDs)
            defaults.set([], forKey: Preferences.Key.excludedBundleIDs)
            let state = self.state
            model = SwitcherModel(focusTracker: tracker, defaults: defaults, dependencies: .init(
                enumerate: { _, options in
                    state.apps.filter { !options.excludedBundleIDs.contains($0.bundleIdentifier ?? "") }
                        .compactMap { app -> AppEntry? in
                            var entry = app
                            entry.windows = app.windows.filter(options.includes)
                            return app.windows.isEmpty || !entry.windows.isEmpty ? entry : nil
                        }
                },
                focusApp: { app in
                    state.focusedApps.append(app.pid)
                    state.frontmostPID = app.pid
                    state.focusedByPID[app.pid] = app.windows.first?.id
                },
                focusWindow: { window in
                    state.focusedWindows.append(window.id)
                    state.frontmostPID = window.pid
                    state.focusedByPID[window.pid] = window.id
                },
                closeWindow: { _ in state.actions.append("close"); return false },
                minimizeWindow: { _ in state.actions.append("minimize"); return false },
                zoomWindow: { _ in state.actions.append("zoom"); return false },
                hideApp: { _ in state.actions.append("hide"); return false },
                focusPID: { pid in state.fallbackPIDs.append(pid); state.frontmostPID = pid },
                restoreWindowFocus: { pid, id in
                    state.restoreRequests.append(.init(pid: pid, id: id))
                    guard state.canRestore, state.apps.contains(where: { $0.pid == pid && $0.windows.contains(where: { $0.id == id }) })
                    else { return false }
                    state.frontmostPID = pid
                    state.focusedByPID[pid] = id
                    return true
                },
                frontmostPID: { state.frontmostPID },
                frontmostBundleID: { state.bundleOverride ?? state.apps.first(where: { $0.pid == state.frontmostPID })?.bundleIdentifier },
                focusedWindowID: { state.focusedByPID[$0] }
            ))
        }

        deinit {
            model.cancel()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
