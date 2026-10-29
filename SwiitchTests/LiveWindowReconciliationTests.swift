import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class LiveWindowReconciliationTests: XCTestCase {
    func testInventoryDistinguishesFailureFromEmptyAndIgnoresWindowFiltering() {
        XCTAssertNil(WindowEnumerator.WindowInventory.from(rows: nil, collectedAt: 1))
        XCTAssertNil(WindowEnumerator.WindowInventory.from(rows: [[kCGWindowNumber as String: 1]], collectedAt: 1))
        XCTAssertEqual(WindowEnumerator.WindowInventory.from(rows: [], collectedAt: 1)?.owners, [:])
        let rows: [[String: Any]] = [
            [kCGWindowNumber as String: UInt32(1), kCGWindowOwnerPID as String: Int32(101),
             kCGWindowAlpha as String: 0, kCGWindowIsOnscreen as String: false],
            [kCGWindowNumber as String: UInt32(2), kCGWindowOwnerPID as String: Int32(102)],
        ]
        XCTAssertEqual(WindowEnumerator.WindowInventory.from(rows: rows, collectedAt: 1)?.owners, [1: 101, 2: 102],
                       "Hidden/off-Space/missing-title windows still exist")
    }

    func testRemovalKeepsSurvivingOrderSelectionAndFrameWithoutAddingNewWindows() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        XCTAssertTrue(fixture.model.selectVisible(ordinal: 3))
        let selected = fixture.model.flatWindows[fixture.model.selectedFlatIndex].id
        let order = fixture.model.flatWindows.map(\.id)
        var reflows = 0
        fixture.model.onUpdate = { reflows += 1 }
        fixture.update([12: 101, 21: 102, 22: 102, 99: 999])
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), order.filter { $0 != 11 })
        XCTAssertEqual(fixture.model.flatWindows[fixture.model.selectedFlatIndex].id, selected)
        XCTAssertEqual(reflows, 0)
        XCTAssertTrue(fixture.focused.isEmpty)
    }

    func testRemovedFilteredSelectionUsesItsVisibleNeighborAndPreservesQuery() {
        let fixture = Fixture()
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("Beta")
        fixture.model.selectEdge(last: true)
        XCTAssertEqual(fixture.model.filteredFlatWindows.map(\.id), [21, 22])
        fixture.update([11: 101, 12: 101, 21: 102])
        XCTAssertEqual(fixture.model.filterText, "Beta")
        XCTAssertEqual(fixture.model.flatWindows[fixture.model.selectedFlatIndex].id, 21)
        fixture.update([11: 101, 12: 101])
        XCTAssertTrue(fixture.model.filteredFlatWindows.isEmpty)
        XCTAssertTrue(fixture.model.isArmed, "An empty search is not an empty invocation")
        fixture.model.commit()
        XCTAssertTrue(fixture.focused.isEmpty)
    }

    func testDrilledWindowRemovalKeepsAppThenReturnsToAppsWhenLastWindowCloses() {
        let fixture = Fixture(appsMode: true)
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.currentApp?.pid, 102)
        fixture.model.enterWindowMode()
        fixture.model.selectEdge(last: true)
        fixture.update([11: 101, 12: 101, 22: 102])
        XCTAssertEqual(fixture.model.mode, .windowsForApp)
        XCTAssertEqual(fixture.model.selectedVisibleAppWindow?.id, 22)
        fixture.update([11: 101, 12: 101])
        XCTAssertEqual(fixture.model.mode, .apps)
        XCTAssertEqual(fixture.model.currentApp?.pid, 101)
    }

    func testCurrentAppModeNeverBroadensWhenItsLastWindowCloses() {
        let fixture = Fixture()
        fixture.model.armForCurrentApp(reverse: false)
        fixture.update([21: 102, 22: 102])
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.model.flatWindows.isEmpty)
        XCTAssertFalse(fixture.tracker.isTrackingSuspended)
    }

    func testAppsModeKeepsSelectedAppAfterEarlierAppDisappears() {
        let fixture = Fixture(appsMode: true)
        fixture.model.arm(reverse: false)
        XCTAssertEqual(fixture.model.currentApp?.pid, 102)
        fixture.update([21: 102, 22: 102])
        XCTAssertEqual(fixture.model.currentApp?.pid, 102)
        XCTAssertEqual(fixture.model.selectedAppIndex, 0)
        XCTAssertTrue(fixture.focused.isEmpty)
    }

    func testLosingDrilledAppRestoresOriginalSearchWithoutSelectingAnUnmatchedApp() {
        let fixture = Fixture(appsMode: true)
        fixture.model.arm(reverse: false)
        fixture.model.appendFilter("Beta")
        fixture.model.enterWindowMode()
        fixture.model.appendFilter("22")
        fixture.update([11: 101, 12: 101])
        XCTAssertEqual(fixture.model.mode, .apps)
        XCTAssertEqual(fixture.model.filterText, "Beta")
        XCTAssertTrue(fixture.model.filteredApps.isEmpty)
        XCTAssertTrue(fixture.model.isArmed)
        fixture.model.commit()
        XCTAssertTrue(fixture.focused.isEmpty)
    }

    func testOldCollectionCannotPruneNewInvocationAndReusedIDIsRemoved() {
        let fixture = Fixture()
        let beforeOpen = ProcessInfo.processInfo.systemUptime - 1
        fixture.model.arm(reverse: false)
        fixture.model.reconcileClosedWindows(in: .init(owners: [:], collectedAt: beforeOpen))
        XCTAssertEqual(fixture.model.flatWindows.count, 4)
        fixture.update([11: 999, 12: 101, 21: 102, 22: 102])
        XCTAssertFalse(fixture.model.flatWindows.contains { $0.id == 11 }, "A reused window ID is not the old document")
        fixture.update([:])
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertFalse(fixture.tracker.isTrackingSuspended)
        fixture.update([:])
        XCTAssertTrue(fixture.focused.isEmpty)
    }

    func testDiscoveryPublishesOnlySuccessfulCurrentInventoryNotCachedOrFailedReads() async {
        let gate = DiscoveryGate()
        let service = WindowDiscovery(collector: { _ in
            await gate.wait()
            return .init(apps: [], duration: 0, candidateCount: 0, filteredCount: 0, unavailableAXCount: 0,
                         inventory: .init(owners: [11: 101], collectedAt: 1))
        })
        var updates = 0
        service.onWindowInventory = { _ in updates += 1 }
        let context = WindowEnumerator.Context(applications: [], options: .init(), screenFrame: nil)
        let request = Task { await service.prepare(context: context) }
        await waitUntil("collection to start") { await gate.waiterCount == 1 }
        service.setBackgroundWorkPaused(true)
        await gate.release()
        await request.value
        XCTAssertEqual(updates, 0, "A pre-sleep snapshot must not reach the picker")
        service.setBackgroundWorkPaused(false)
        await service.prepare(context: context)
        await service.prepare(context: context)
        XCTAssertEqual(updates, 1)
        let failed = WindowDiscovery(collector: { _ in nil })
        failed.onWindowInventory = { _ in XCTFail("A failed read is not evidence of closed windows") }
        await failed.prepare(context: context)
    }

    @MainActor
    private final class Fixture {
        let suite = "LiveWindowReconciliationTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let tracker = FocusTracker()
        var focused: [CGWindowID] = []
        var model: SwitcherModel!

        init(appsMode: Bool = false) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(appsMode ? "apps" : "windows", forKey: Preferences.Key.displayMode)
            defaults.set(0, forKey: Preferences.Key.switcherShowDelayMs)
            defaults.set(false, forKey: Preferences.Key.peekOnHover)
            let apps = [(Int32(101), "Alpha", [UInt32(11), 12]), (Int32(102), "Beta", [UInt32(21), 22])].map { pid, name, ids in
                AppEntry(pid: pid, bundleIdentifier: name, name: name, icon: nil, windows: ids.map {
                    WindowInfo(id: $0, pid: pid, title: "\(name) \($0)", bounds: .zero, isOnScreen: true)
                })
            }
            model = SwitcherModel(focusTracker: tracker, defaults: defaults, dependencies: .init(
                enumerate: { _, _ in apps }, focusApp: { _ in }, focusWindow: { [weak self] in self?.focused.append($0.id) },
                closeWindow: { _ in false }, hideApp: { _ in false }, focusPID: { _ in },
                frontmostPID: { 101 }, frontmostBundleID: { "Alpha" }, focusedWindowID: { _ in 11 }))
        }

        func update(_ owners: [CGWindowID: pid_t]) {
            model.reconcileClosedWindows(in: .init(owners: owners, collectedAt: ProcessInfo.processInfo.systemUptime))
        }

        deinit {
            MainActor.assumeIsolated {
                model.cancel()
                defaults.removePersistentDomain(forName: suite)
            }
        }
    }
}
