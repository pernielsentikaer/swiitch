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

    func testPickerRefreshDuringBackgroundDelayIsNotRepeatedButNextEventStillCollects() async {
        let count = EventCollectionCount()
        let clock = EventRefreshClock()
        let discovery = WindowDiscovery(now: { clock.now }, contextProvider: { _ in
            .init(applications: [], options: .init(), screenFrame: nil)
        }, collector: { _ in await count.increment(); return Self.emptyCollection() })
        var completed = 0
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { await discovery.refreshAfterChange(); completed += 1 },
            observeApplication: { _, _ in nil }, windowElements: { _ in [] },
            now: { clock.now }, sleep: { await clock.sleep($0) }
        ))
        discovery.eventMonitor = monitor
        monitor.start()
        defer { monitor.stop(); clock.releaseAll() }
        await discovery.prepare(options: .init())
        monitor.handle("AXWindowCreated")
        await waitUntil("the pending background refresh") { clock.pendingCount == 1 }

        // No release of the background delay: a user request must be immediately fresh.
        await discovery.prepare(options: .init())
        var total = await count.value
        XCTAssertEqual(total, 2)
        XCTAssertEqual(completed, 0)
        clock.releaseNext()
        await waitUntil("background refresh reusing the user's result") { completed == 1 }
        total = await count.value
        XCTAssertEqual(total, 2, "The event generation was already collected by the picker")

        monitor.handle("AXWindowMoved")
        await waitUntil("a throttled background refresh") { clock.pendingCount == 1 }
        clock.releaseNext()
        await waitUntil("the next event to collect") { completed == 2 }
        total = await count.value
        XCTAssertEqual(total, 3, "A newer event cannot be mistaken for the already covered one")

        await discovery.prepare(options: .init(forceRefresh: true))
        total = await count.value
        XCTAssertEqual(total, 4, "Explicit forced refreshes still bypass the cache")
    }

    func testBackgroundRefreshJoinsUserCollectionAlreadyCoveringTheEvent() async {
        let count = EventCollectionCount()
        let gate = DiscoveryGate()
        let clock = EventRefreshClock()
        let discovery = WindowDiscovery(now: { clock.now }, contextProvider: { _ in
            .init(applications: [], options: .init(), screenFrame: nil)
        }, collector: { _ in
            await count.increment()
            await gate.wait()
            return Self.emptyCollection()
        })
        var completed = false
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { await discovery.refreshAfterChange(); completed = true },
            observeApplication: { _, _ in nil }, windowElements: { _ in [] },
            now: { clock.now }, sleep: { await clock.sleep($0) }
        ))
        discovery.eventMonitor = monitor
        monitor.start()
        defer { monitor.stop(); clock.releaseAll() }
        monitor.handle("AXWindowCreated")
        await waitUntil("background delay") { clock.pendingCount == 1 }
        let user = Task { await discovery.prepare(options: .init()) }
        await waitUntil("the user's collection to start") { await gate.waiterCount == 1 }
        clock.releaseNext()
        await waitUntil("background request to join the user's collection") { discovery.coalescedRequestCount == 1 }
        await gate.release()
        await user.value
        await waitUntil("background request to finish") { completed }
        let total = await count.value
        XCTAssertEqual(total, 1, "Joining a fresh collection must not force a second one afterwards")
    }

    func testBackgroundRefreshCannotReuseCollectionBegunBeforeTheEvent() async {
        let count = EventCollectionCount()
        let gate = DiscoveryGate()
        let clock = EventRefreshClock()
        let discovery = WindowDiscovery(now: { clock.now }, contextProvider: { _ in
            .init(applications: [], options: .init(), screenFrame: nil)
        }, collector: { _ in
            await count.increment()
            await gate.wait()
            return Self.emptyCollection()
        })
        var completed = false
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { await discovery.refreshAfterChange(); completed = true },
            observeApplication: { _, _ in nil }, windowElements: { _ in [] },
            now: { clock.now }, sleep: { await clock.sleep($0) }
        ))
        discovery.eventMonitor = monitor
        monitor.start()
        defer { monitor.stop(); clock.releaseAll() }
        let old = Task { await discovery.prepare(options: .init()) }
        await waitUntil("a collection begun before the change") { await gate.waiterCount == 1 }
        monitor.handle("AXWindowCreated")
        await waitUntil("background delay") { clock.pendingCount == 1 }
        clock.releaseNext()
        await waitUntil("the background request to wait for the older collection") { discovery.coalescedRequestCount == 1 }
        await gate.release()
        await old.value
        await waitUntil("a fresh follow-up collection") { completed }
        let total = await count.value
        XCTAssertEqual(total, 2, "The newer event still needs a collection that actually covers it")
    }

    func testChangeRefreshWithoutAnActiveMonitorStillForcesCollection() async {
        let count = EventCollectionCount()
        let discovery = WindowDiscovery(contextProvider: { _ in
            .init(applications: [], options: .init(), screenFrame: nil)
        }, collector: { _ in await count.increment(); return Self.emptyCollection() })
        await discovery.prepare(options: .init())
        await discovery.refreshAfterChange()
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { false }, refresh: {}, observeApplication: { _, _ in nil }, windowElements: { _ in [] }
        ))
        discovery.eventMonitor = monitor
        await discovery.refreshAfterChange()
        let total = await count.value
        XCTAssertEqual(total, 3, "Without active event generations, an announced change must force fresh data")
    }
}

private actor EventCollectionCount {
    private(set) var value = 0
    func increment() { value += 1 }
}
