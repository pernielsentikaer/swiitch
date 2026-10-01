import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class EventDiscoveryRegressionTests: XCTestCase {
    private nonisolated static func emptyCollection() -> WindowEnumerator.Collection {
        .init(apps: [], duration: 0.01, candidateCount: 0, filteredCount: 0, unavailableAXCount: 0)
    }

    func testRunningWindowlessAppMustParticipateInCoverage() async {
        var observed: [pid_t] = []
        let discovery = WindowDiscovery(collector: { _ in Self.emptyCollection() })
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: {},
            observeApplication: { pid, _ in observed.append(pid); return nil },
            windowElements: { _ in [] }))
        discovery.eventMonitor = monitor
        monitor.start()
        defer { monitor.stop() }
        let context = WindowEnumerator.Context(applications: [
            .init(processIdentifier: 123, bundleIdentifier: "test.windowless", localizedName: "Windowless", icon: nil)
        ], options: .init(), screenFrame: nil)
        await discovery.prepare(context: context)
        XCTAssertEqual(observed, [123], "First-window creation requires observing windowless apps")
        XCTAssertFalse(monitor.coversEveryApp)
    }

    func testUserRequestAfterEventMustNotReuseSnapshotDuringDebounce() async {
        let count = EventCollectionCount()
        let discovery = WindowDiscovery(collector: { _ in await count.increment(); return Self.emptyCollection() })
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: {}, observeApplication: { _, _ in nil }, windowElements: { _ in [] }))
        discovery.eventMonitor = monitor
        monitor.start()
        defer { monitor.stop() }
        let context = WindowEnumerator.Context(applications: [], options: .init(), screenFrame: nil)
        await discovery.prepare(context: context)
        monitor.handle("AXWindowCreated")
        await discovery.prepare(context: context)
        let total = await count.value
        XCTAssertEqual(total, 2, "Opening immediately after an event cannot reuse known-stale metadata")
    }

    func testEventDuringCollectionCannotMakeThatSnapshotFreshForAWaitingUser() async {
        let count = EventCollectionCount()
        let gate = DiscoveryGate()
        let discovery = WindowDiscovery(collector: { _ in
            await count.increment()
            await gate.wait()
            return Self.emptyCollection()
        })
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: {}, observeApplication: { _, _ in nil }, windowElements: { _ in [] }))
        discovery.eventMonitor = monitor
        monitor.start()
        defer { monitor.stop() }
        let context = WindowEnumerator.Context(applications: [], options: .init(), screenFrame: nil)
        let first = Task { await discovery.prepare(context: context) }
        await waitUntil("the initial collection to start") { await gate.waiterCount == 1 }
        monitor.handle("AXWindowCreated")
        let user = Task { await discovery.prepare(context: context) }
        await waitUntil("the user request to join") { discovery.coalescedRequestCount == 1 }
        await gate.release()
        await first.value
        await user.value
        let total = await count.value
        XCTAssertEqual(total, 2, "The user must get a collection begun after the change")
    }

    func testEventsDuringRefreshScheduleOneTrailingRefreshWithoutOverlap() async throws {
        let gate = DiscoveryGate()
        var active = 0
        var maximumActive = 0
        var completed = 0
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: {
                active += 1
                maximumActive = max(maximumActive, active)
                await gate.wait()
                active -= 1
                completed += 1
            }, observeApplication: { _, _ in nil }, windowElements: { _ in [] }))
        monitor.start()
        defer { monitor.stop() }
        monitor.handle("AXWindowCreated")
        await waitUntil("the first refresh to block") { active == 1 }
        for _ in 0..<5 { monitor.handle("AXWindowMoved") }
        // Negative assertion: give an incorrectly overlapping refresh time to fire.
        try await Task.sleep(for: .seconds(WindowEventMonitor.coalescingInterval * 4))
        XCTAssertEqual(maximumActive, 1)
        await gate.release()
        await waitUntil("one trailing refresh to finish") { completed == 2 }
        XCTAssertEqual(monitor.refreshCount, 2)
        XCTAssertEqual(maximumActive, 1)
    }

    func testPartialNotificationSupportDoesNotClaimCompleteCoverage() {
        typealias Observation = WindowEventMonitor.AppObservation
        XCTAssertFalse(Observation.subscriptionsAreComplete([]))
        XCTAssertFalse(Observation.subscriptionsAreComplete([.success, .notificationUnsupported]))
        XCTAssertTrue(Observation.subscriptionsAreComplete([.success, .notificationAlreadyRegistered]))
    }
}

private actor EventCollectionCount {
    private(set) var value = 0
    func increment() { value += 1 }
}
