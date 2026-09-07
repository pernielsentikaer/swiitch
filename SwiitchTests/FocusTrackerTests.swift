import AppKit
@testable import Swiitch
import XCTest

final class FocusTrackerTests: XCTestCase {
    func testVisitsReorderIndividualWindowsWithoutDuplicates() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 1, pid: 101)
        tracker.bumpWindow(id: 2, pid: 101)
        tracker.bumpWindow(id: 1, pid: 101)
        tracker.bumpWindow(id: 1, pid: 101)

        XCTAssertEqual(tracker.mruWindows.map(\.id), [1, 2])
    }

    func testWindowHistoryIsGlobalAcrossApps() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 1, pid: 101)
        tracker.bumpWindow(id: 3, pid: 102)
        tracker.bumpWindow(id: 2, pid: 101)

        let windows = [window(1), window(2), window(3, pid: 102)]
        XCTAssertEqual(tracker.windowOrder.sorted(windows, window: { $0 }).map(\.id), [2, 3, 1])
    }

    func testUnknownWindowsRetainTheirInputOrder() {
        let tracker = FocusTracker()
        let windows = [window(3), window(1), window(2)]
        XCTAssertEqual(tracker.windowOrder.sorted(windows, window: { $0 }).map(\.id), [3, 1, 2])

        tracker.bumpWindow(id: 1, pid: 101)
        XCTAssertEqual(tracker.windowOrder.sorted(windows, window: { $0 }).map(\.id), [1, 3, 2])
    }

    func testSnapshotDoesNotChangeWhenAnotherWindowIsVisited() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 1, pid: 101)
        let snapshot = tracker.windowOrder
        tracker.bumpWindow(id: 2, pid: 101)
        let windows = [window(1), window(2)]

        XCTAssertEqual(snapshot.sorted(windows, window: { $0 }).map(\.id), [1, 2])
        XCTAssertEqual(tracker.windowOrder.sorted(windows, window: { $0 }).map(\.id), [2, 1])
    }

    func testPinnedRankTakesPriorityOverRecency() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 1, pid: 101)
        let windows = [window(1), window(2), window(3)]
        let ordered = tracker.windowOrder.sorted(windows, window: { $0 }, pinnedRank: {
            $0.id == 3 ? 0 : ($0.id == 2 ? 1 : .max)
        })
        XCTAssertEqual(ordered.map(\.id), [3, 2, 1])
    }

    func testPreviewDoesNotEnterHistoryAndTrackingResumes() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 1, pid: 101)
        tracker.isWindowTrackingSuspended = true
        tracker.bumpWindow(id: 2, pid: 101)
        XCTAssertEqual(tracker.mruWindows.map(\.id), [1])

        tracker.isWindowTrackingSuspended = false
        tracker.bumpWindow(id: 2, pid: 101)
        XCTAssertEqual(tracker.mruWindows.map(\.id), [2, 1])
    }

    func testReusedWindowIDInAnotherProcessDoesNotInheritRank() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 1, pid: 101)
        let windows = [window(2, pid: 202), window(1, pid: 202)]
        XCTAssertEqual(tracker.windowOrder.sorted(windows, window: { $0 }).map(\.id), [2, 1])
    }

    func testTerminationRemovesOnlyThatProcessesHistory() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 1, pid: 101)
        tracker.bumpWindow(id: 2, pid: 202)
        tracker.bumpWindow(id: 3, pid: 101)
        tracker.removeWindows(forPID: 101)
        XCTAssertEqual(tracker.mruWindows, [.init(pid: 202, id: 2)])
    }

    func testHistoryIsBoundedAndInvalidIdentitiesAreIgnored() {
        let tracker = FocusTracker()
        tracker.bumpWindow(id: 0, pid: 101)
        tracker.bumpWindow(id: 1, pid: 0)
        tracker.bumpWindow(id: 1, pid: -1)
        XCTAssertTrue(tracker.mruWindows.isEmpty)

        for id in 1...600 { tracker.bumpWindow(id: CGWindowID(id), pid: 101) }
        XCTAssertEqual(tracker.mruWindows.count, 512)
        XCTAssertEqual(tracker.mruWindows.first?.id, 600)
        XCTAssertEqual(tracker.mruWindows.last?.id, 89)
    }

    private func window(_ id: CGWindowID, pid: pid_t = 101) -> WindowInfo {
        WindowInfo(id: id, pid: pid, title: "Window", bounds: .zero, isOnScreen: true)
    }
}
