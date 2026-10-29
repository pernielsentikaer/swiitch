@testable import Swiitch
import XCTest

@MainActor
final class WindowEventMonitorTests: XCTestCase {
    func testPauseRetainsInvalidationsWithoutSchedulingAndCoalescesOnResume() async {
        let clock = EventRefreshClock()
        var refreshes = 0
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { refreshes += 1 },
            observeApplication: { _, _ in nil }, windowElements: { _ in [] },
            now: { clock.now }, sleep: { await clock.sleep($0) }
        ))
        monitor.start()
        defer { monitor.stop(); clock.releaseAll() }
        monitor.handle("AXWindowMoved")
        await waitUntil("pending refresh") { clock.pendingCount == 1 }
        monitor.setBackgroundWorkPaused(true)
        for _ in 0..<100 { monitor.handle("AXWindowMoved") }
        XCTAssertEqual(monitor.eventCount, 101, "Events must still invalidate a discovery snapshot")
        XCTAssertEqual(clock.pendingCount, 1, "No new scheduled work while paused")
        monitor.setBackgroundWorkPaused(false)
        await waitUntil("resumed refresh alongside the cancelled wait") { clock.pendingCount == 2 }
        clock.releaseAll()
        await waitUntil("only the resumed refresh") { refreshes == 1 }
        XCTAssertEqual(monitor.refreshCount, 1)
        monitor.setBackgroundWorkPaused(true)
        monitor.setBackgroundWorkPaused(false)
        await Task.yield()
        XCTAssertEqual(clock.pendingCount, 0, "No fabricated refresh without a change")
    }

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

    func testRepeatedBurstsAreRateLimitedWithoutDelayingFirstEventAfterQuiet() async {
        let clock = EventRefreshClock()
        var starts: [TimeInterval] = []
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { starts.append(clock.now) },
            observeApplication: { _, _ in nil }, windowElements: { _ in [] },
            now: { clock.now }, sleep: { await clock.sleep($0) }
        ))
        monitor.start()
        defer { monitor.stop(); clock.releaseAll() }

        for batch in 0..<5 {
            for _ in 0..<20 { monitor.handle("AXWindowResized") }
            await waitUntil("one scheduled refresh") { clock.pendingCount == 1 }
            let delay = clock.delays.last ?? -1
            XCTAssertEqual(delay, batch == 0 ? 0.05 : 0.25, accuracy: 0.0001)
            XCTAssertEqual(starts.count, batch, "No refresh before the scheduled deadline")
            // More events inside the wait neither add work nor postpone it indefinitely.
            for _ in 0..<20 { monitor.handle("AXWindowMoved") }
            XCTAssertEqual(clock.pendingCount, 1)
            clock.releaseNext()
            await waitUntil("the scheduled refresh to complete") { starts.count == batch + 1 }
        }
        XCTAssertEqual(monitor.eventCount, 200)
        XCTAssertEqual(monitor.refreshCount, 5)
        XCTAssertEqual(starts.first ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertEqual((starts.last ?? -1) - (starts.first ?? 0), 1, accuracy: 0.0001)

        clock.now += 10
        monitor.handle("AXWindowCreated")
        await waitUntil("the first event after quiet") { clock.pendingCount == 1 }
        XCTAssertEqual(clock.delays.last ?? -1, 0.05, accuracy: 0.0001)
        clock.releaseNext()
        await waitUntil("the final update") { starts.count == 6 }
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testSlowCollectionDoesNotPayAnotherFullRateLimitDelay() async {
        let clock = EventRefreshClock()
        var refreshes = 0
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { refreshes += 1; clock.now += 0.6 },
            observeApplication: { _, _ in nil }, windowElements: { _ in [] },
            now: { clock.now }, sleep: { await clock.sleep($0) }
        ))
        monitor.start()
        defer { monitor.stop(); clock.releaseAll() }
        monitor.handle("AXWindowCreated")
        await waitUntil("the initial delay") { clock.pendingCount == 1 }
        clock.releaseNext()
        await waitUntil("the slow collection to finish") { refreshes == 1 }
        monitor.handle("AXWindowMoved")
        await waitUntil("the follow-up delay") { clock.pendingCount == 1 }
        XCTAssertEqual(clock.delays.last ?? -1, 0.05, accuracy: 0.0001,
                       "Rate limiting is start-to-start, not an extra pause after a slow scan")
        clock.releaseNext()
        await waitUntil("the follow-up collection") { refreshes == 2 }
    }

    func testStopAndRestartCannotDeliverOldDelayedRefreshOrInheritItsThrottle() async {
        let clock = EventRefreshClock()
        var refreshes = 0
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { refreshes += 1 },
            observeApplication: { _, _ in nil }, windowElements: { _ in [] },
            now: { clock.now }, sleep: { await clock.sleep($0) }
        ))
        monitor.start()
        defer { monitor.stop(); clock.releaseAll() }
        monitor.handle("AXWindowCreated")
        await waitUntil("initial delay") { clock.pendingCount == 1 }
        clock.releaseNext()
        await waitUntil("initial refresh") { refreshes == 1 }
        monitor.handle("AXWindowMoved")
        await waitUntil("throttled delay") { clock.pendingCount == 1 }
        monitor.stop()
        monitor.start()
        monitor.handle("AXWindowCreated")
        await waitUntil("new lifecycle's delay alongside the cancelled delay") { clock.pendingCount == 2 }
        XCTAssertEqual(clock.delays.last ?? -1, 0.05, accuracy: 0.0001)
        clock.releaseAll()
        await waitUntil("only the new lifecycle's refresh") { refreshes == 2 }
        XCTAssertEqual(monitor.refreshCount, 2)
        monitor.handle("AXWindowMoved")
        await waitUntil("the new lifecycle remains usable") { clock.pendingCount == 1 }
        clock.releaseNext()
        await waitUntil("one further refresh") { refreshes == 3 }
        XCTAssertEqual(monitor.refreshCount, 3)
    }
}

/// Manual monotonic clock: tests release scheduled work explicitly, without waiting for
/// wall-clock debounce/rate-limit intervals. Even cancelled waits can be released late.
@MainActor
final class EventRefreshClock {
    var now: TimeInterval = 0
    private(set) var delays: [TimeInterval] = []
    private var pending: [(deadline: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
    var pendingCount: Int { pending.count }

    func sleep(_ interval: TimeInterval) async {
        delays.append(interval)
        await withCheckedContinuation { pending.append((now + interval, $0)) }
    }

    func releaseNext() {
        guard !pending.isEmpty else { return }
        let next = pending.removeFirst()
        now = max(now, next.deadline)
        next.continuation.resume()
    }

    func releaseAll() {
        while !pending.isEmpty { releaseNext() }
    }
}
