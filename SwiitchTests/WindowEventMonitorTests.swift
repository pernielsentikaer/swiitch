@testable import Swiitch
import XCTest

@MainActor
final class WindowEventMonitorTests: XCTestCase {
    private final class Log {
        var refreshes = 0
        var observed: [pid_t] = []
    }

    private func makeMonitor(_ log: Log, trusted: Bool = true) -> WindowEventMonitor {
        WindowEventMonitor(dependencies: .init(
            trusted: { trusted },
            refresh: { log.refreshes += 1 },
            observeApplication: { pid, _ in log.observed.append(pid); return .init(pid: pid) },
            windowElements: { _ in [] }
        ))
    }

    private func collection(_ apps: [(pid_t, [CGWindowID])]) -> WindowEnumerator.Collection {
        .init(apps: apps.map { pid, ids in
            AppEntry(pid: pid, bundleIdentifier: nil, name: "App \(pid)", icon: nil, windows: ids.map {
                WindowInfo(id: $0, pid: pid, title: "W\($0)", bounds: .zero, isOnScreen: true)
            })
        }, duration: 0.01, candidateCount: 0, filteredCount: 0, unavailableAXCount: 0)
    }

    func testObserversFollowTheCollectedAppsAndWindows() {
        let log = Log()
        let monitor = makeMonitor(log)
        monitor.reconcile(with: collection([(1, [10])]))
        XCTAssertEqual(monitor.observedApplicationCount, 0, "Nothing is observed before start")

        monitor.start()
        XCTAssertTrue(monitor.isActive)
        monitor.reconcile(with: collection([(1, [10, 11]), (2, [20])]))
        XCTAssertEqual(log.observed.sorted(), [1, 2], "One observer per app")
        XCTAssertEqual(monitor.observedApplicationCount, 2)
        XCTAssertEqual(monitor.trackedWindowCount, 3)
        XCTAssertFalse(monitor.coversEveryApp, "Test observations have no live AX observer, so coverage is incomplete")

        monitor.reconcile(with: collection([(1, [11, 12])]))
        XCTAssertEqual(monitor.observedApplicationCount, 1, "A vanished app's observer is dropped")
        XCTAssertEqual(monitor.trackedWindowCount, 2, "Closed windows are forgotten, new ones tracked")
        XCTAssertEqual(log.observed.count, 2, "An existing app is not re-observed")

        monitor.stop()
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(monitor.observedApplicationCount, 0)
    }

    func testEventsCoalesceIntoOneRefreshAndStopSilencesThem() async throws {
        let log = Log()
        let monitor = makeMonitor(log)
        monitor.start()
        for _ in 0..<5 { monitor.handle("AXWindowCreated") }
        XCTAssertEqual(monitor.eventCount, 5)
        XCTAssertEqual(log.refreshes, 0, "Refresh waits for the burst to settle")
        await waitUntil("the burst to settle into one refresh") { log.refreshes == 1 }
        XCTAssertEqual(monitor.refreshCount, 1)
        // Let a second refresh land if the burst had wrongly produced one.
        try await Task.sleep(for: .seconds(WindowEventMonitor.coalescingInterval * 4))
        XCTAssertEqual(log.refreshes, 1, "A burst of events becomes one collection")

        monitor.stop()
        monitor.handle("AXWindowCreated")
        try await Task.sleep(for: .seconds(WindowEventMonitor.coalescingInterval * 4))
        XCTAssertEqual(log.refreshes, 1, "A stopped monitor ignores events")
    }

    func testMonitorDoesNotStartWithoutAccessibility() {
        let log = Log()
        let monitor = makeMonitor(log, trusted: false)
        monitor.start()
        XCTAssertFalse(monitor.isActive)
        monitor.handle("AXWindowCreated")
        XCTAssertEqual(monitor.eventCount, 0)
    }
}
