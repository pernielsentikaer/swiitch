import AppKit
@testable import Swiitch
import XCTest

/// A deliberately non-cooperative operation: release explicitly even after timeout.
actor DiscoveryGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Collectors currently blocked here; proves a collection is in flight.
    var waiterCount: Int { waiters.count }
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class WindowDiscoveryTests: XCTestCase {
    private func context(excluded: Set<String> = []) -> WindowEnumerator.Context {
        .init(applications: [], options: .init(excludedBundleIDs: excluded), screenFrame: nil)
    }

    private nonisolated static func collection() -> WindowEnumerator.Collection {
        .init(apps: [], duration: 0.01, candidateCount: 3, filteredCount: 1, unavailableAXCount: 0)
    }

    func testCollectionRunsOffMainAndRecentSnapshotAvoidsRepeatWork() async {
        let count = DiscoveryCount()
        let service = WindowDiscovery(collector: { _ in
            XCTAssertFalse(Thread.isMainThread)
            await count.add()
            return Self.collection()
        })
        await service.prepare(context: context())
        await service.prepare(context: context())
        let total = await count.value
        XCTAssertEqual(total, 1)
        XCTAssertEqual(service.cacheHits, 1)
        XCTAssertEqual(service.lastCollection?.candidateCount, 3)
    }

    func testSuccessfulAccessibilityMemoryReachesTheNextCollection() async {
        let memory: [pid_t: WindowEnumerator.AccessibilityMemory] = [
            300: .init(windowIDs: [1], observedWindowIDs: [1, 2], recordedAt: 10),
        ]
        let service = WindowDiscovery(collector: { context in
            if !context.options.excludedBundleIDs.isEmpty {
                XCTAssertEqual(context.accessibilityMemory, memory)
            }
            var result = Self.collection()
            result.accessibilityMemory = memory
            return result
        })
        await service.prepare(context: context())
        await service.prepare(context: context(excluded: ["example.private"]))
        XCTAssertEqual(service.lastCollection?.accessibilityMemory, memory)
        XCTAssertEqual(service.timeoutCount, 0)
    }

    func testConcurrentRequestsCoalesceAndDifferentExclusionsRefresh() async {
        let count = DiscoveryCount()
        let gate = DiscoveryGate()
        let service = WindowDiscovery(collector: { _ in
            await count.add()
            await gate.wait()
            return Self.collection()
        })
        let first = Task { await service.prepare(context: context()) }
        let second = Task { await service.prepare(context: context()) }
        await waitUntil("the second request to join the first") { service.coalescedRequestCount == 1 }
        await gate.release()
        await first.value
        await second.value
        let total = await count.value
        XCTAssertEqual(total, 1)
        await service.prepare(context: context(excluded: ["example.private"]))
        let changed = await count.value
        XCTAssertEqual(changed, 2)
    }

    func testSlowCollectorDoesNotBlockMainAndDeadlineBoundsCallersAndWorkers() async {
        let gate = DiscoveryGate()
        let count = DiscoveryCount()
        let service = WindowDiscovery(timeout: 0.03, collector: { _ in
            await count.add()
            await gate.wait()
            return Self.collection()
        })
        var completed = false
        let task = Task { await service.prepare(context: context()); completed = true }
        var heartbeat = false
        DispatchQueue.main.async { heartbeat = true }
        await waitUntil("the deadline to release the caller before the stalled worker returns") { completed }
        XCTAssertTrue(heartbeat, "The main thread kept running while the collector stalled")
        for _ in 0..<5 { await service.prepare(context: context()) }
        let total = await count.value
        XCTAssertEqual(total, 1, "Timed-out native work keeps its bounded slot")
        XCTAssertNil(service.lastCollection)
        await gate.release()
        await task.value
        // Give the released worker a chance to misbehave before checking it was ignored.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(service.lastCollection, "Late results cannot replace the timed-out snapshot")
        await service.prepare(context: context())
        XCTAssertNotNil(service.lastCollection)
    }

    func testCachedEntriesApplyCurrentSpaceScreenAndExclusions() {
        let a = WindowInfo(id: 1, pid: 10, title: "A", bounds: CGRect(x: 0, y: 0, width: 500, height: 500), isOnScreen: true)
        let b = WindowInfo(id: 2, pid: 10, title: "B", bounds: CGRect(x: 1500, y: 0, width: 500, height: 500), isOnScreen: false)
        let app = AppEntry(pid: 10, bundleIdentifier: "example", name: "Example", icon: nil, windows: [a, b])
        XCTAssertEqual(WindowDiscovery.filtered([app], options: .init(includeOtherSpaces: false), screenFrame: nil).first?.windows.map(\.id), [1])
        XCTAssertEqual(WindowDiscovery.filtered([app], options: .init(), screenFrame: b.bounds).first?.windows.map(\.id), [2])
        XCTAssertTrue(WindowDiscovery.filtered([app], options: .init(excludedBundleIDs: ["example"]), screenFrame: nil).isEmpty)
    }

    func testMinimizedAndOtherSpacesAreIndependentAndUnknownStateIsNotGuessed() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let visible = WindowInfo(id: 1, pid: 10, title: "Visible", bounds: frame, isOnScreen: true, isMinimized: false)
        let minimized = WindowInfo(id: 2, pid: 10, title: "Minimized", bounds: frame, isOnScreen: false, isMinimized: true)
        let otherSpace = WindowInfo(id: 3, pid: 10, title: "Offscreen", bounds: frame, isOnScreen: false, isMinimized: false)
        let unknown = WindowInfo(id: 4, pid: 10, title: "Unknown", bounds: frame, isOnScreen: false)
        let app = AppEntry(pid: 10, bundleIdentifier: "example", name: "Example", icon: nil,
                           windows: [visible, minimized, otherSpace, unknown])
        for (spaces, minimized, expected) in [
            (false, false, [1]), (false, true, [1, 2]),
            (true, false, [1, 3, 4]), (true, true, [1, 2, 3, 4]),
        ] {
            let options = EnumerateOptions(includeOtherSpaces: spaces, includeMinimizedWindows: minimized)
            let ids = WindowDiscovery.filtered([app], options: options, screenFrame: nil).first?.windows.map { Int($0.id) }
            XCTAssertEqual(ids, expected)
            XCTAssertEqual(app.windows.filter { options.includes($0) }.map { Int($0.id) }, expected,
                           "Direct enumeration and warm-cache filtering must agree")
        }
        let elsewhere = CGRect(x: 2000, y: 0, width: 800, height: 600)
        XCTAssertTrue(WindowDiscovery.filtered([app], options: .init(), screenFrame: elsewhere).isEmpty)
    }

    func testConfirmedMinimizedWindowsAreNotClassifiedAsDecorativeDuplicatesOrHosts() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: 0, y: 400, width: 500, height: 500)
        let document = WindowInfo(id: 1, pid: 10, title: "Document", bounds: frame, isOnScreen: true)
        let minimized = WindowInfo(id: 2, pid: 10, title: "", bounds: frame, isOnScreen: false, isMinimized: true)
        let windows = WindowEnumerator.switchableWindows([document, minimized], applicationName: "Example",
                                                        mainDisplayBounds: screen, accessibilityWindowIDs: [1, 2])
        XCTAssertEqual(windows.map(\.id), [1, 2])
    }

    func testColdAndWarmPreparationLatencyWithSlowMetadata() async {
        let service = WindowDiscovery(collector: { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return Self.collection()
        })
        let coldStart = ProcessInfo.processInfo.systemUptime
        await service.prepare(context: context())
        let cold = ProcessInfo.processInfo.systemUptime - coldStart
        let warmStart = ProcessInfo.processInfo.systemUptime
        await service.prepare(context: context())
        let warm = ProcessInfo.processInfo.systemUptime - warmStart
        XCTAssertEqual(service.cacheHits, 1, "The warm request reuses the snapshot instead of collecting again")
        XCTAssertLessThan(warm, cold / 2, "A cache hit must not pay for the injected 200 ms of metadata")
        let attachment = XCTAttachment(string: "Injected slow metadata: cold \(cold * 1000) ms; cached warm \(warm * 1000) ms. Not an installed-app latency benchmark.")
        attachment.name = "Discovery-cold-warm-timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testForcedRefreshDoesNotReuseRecentSnapshot() async {
        let count = DiscoveryCount()
        let service = WindowDiscovery(collector: { _ in await count.add(); return Self.collection() })
        await service.prepare(context: context())
        await service.prepare(context: context(), force: true)
        let total = await count.value
        XCTAssertEqual(total, 2)
    }

    func testIdleBackgroundRefreshReusesSnapshotButUserRequestsStayFresh() async {
        let count = DiscoveryCount()
        let clock = DiscoveryClock()
        let service = WindowDiscovery(now: { clock.now }, collector: { _ in await count.add(); return Self.collection() })

        // Nothing has used the picker yet: keep-warm work may reuse a snapshot for a while.
        await service.prepare(context: context(), background: true)
        clock.now = 5
        await service.prepare(context: context(), background: true)
        var total = await count.value
        XCTAssertEqual(total, 1, "An idle background refresh must not poll every app's AX bridge again")
        XCTAssertEqual(service.snapshotLifetime(background: true), WindowDiscovery.idleSnapshotLifetime)

        // Opening the picker always gets a fresh collection and marks the user as active.
        await service.prepare(options: .init())
        total = await count.value
        XCTAssertEqual(total, 2)
        XCTAssertEqual(service.snapshotLifetime(background: true), WindowDiscovery.activeSnapshotLifetime)

        // While active, background refreshes follow the short lifetime again.
        clock.now = 7
        await service.prepare(context: context(), background: true)
        total = await count.value
        XCTAssertEqual(total, 3)

        // Long after the last user request the long lifetime applies again.
        clock.now = 7 + WindowDiscovery.idleAfter + 1
        await service.prepare(context: context(), background: true)
        clock.now += 5
        await service.prepare(context: context(), background: true)
        total = await count.value
        XCTAssertEqual(total, 4)
        clock.now += WindowDiscovery.idleSnapshotLifetime
        await service.prepare(context: context(), background: true)
        total = await count.value
        XCTAssertEqual(total, 5, "The idle lifetime still expires")
    }

    func testCoveringEventMonitorLetsUserRequestsReuseAFreshSnapshot() async {
        let count = DiscoveryCount()
        let clock = DiscoveryClock()
        let service = WindowDiscovery(now: { clock.now }, collector: { _ in await count.add(); return Self.collection() })
        let monitor = WindowEventMonitor(dependencies: .init(
            trusted: { true }, refresh: { await service.refreshAfterChange() },
            observeApplication: { pid, _ in .init(pid: pid) }, windowElements: { _ in [] }))
        service.eventMonitor = monitor
        monitor.start()

        XCTAssertEqual(service.snapshotLifetime(background: false), WindowDiscovery.activeSnapshotLifetime,
                       "Until a collection has been reconciled, a user request accepts only a one-second-old snapshot")
        // The fixture collection has no apps, so after it the monitor trivially covers every app.
        await service.prepare(context: context())
        XCTAssertTrue(monitor.coversEveryApp)
        XCTAssertEqual(service.snapshotLifetime(background: false), WindowDiscovery.eventDrivenSnapshotLifetime)

        clock.now = 3
        await service.prepare(context: context())
        var total = await count.value
        XCTAssertEqual(total, 1, "Covered and quiet: the picker opens on the cached snapshot")

        clock.now = WindowDiscovery.eventDrivenSnapshotLifetime + 0.5
        await service.prepare(context: context())
        total = await count.value
        XCTAssertEqual(total, 2, "The guard interval still forces a collection")

        // A change notification forces a fresh collection regardless of age.
        monitor.handle("AXWindowCreated")
        await waitUntil("the change notification to force a collection") { await count.value == 3 }

        // Idle and covered, the keep-warm poll only guards against a missed notification.
        clock.now += WindowDiscovery.idleAfter + 1
        XCTAssertEqual(service.snapshotLifetime(background: true), WindowDiscovery.eventDrivenIdleSnapshotLifetime)
        XCTAssertEqual(service.snapshotLifetime(background: false), WindowDiscovery.eventDrivenSnapshotLifetime,
                       "The picker itself still gets a fresher snapshot")
        monitor.stop()
        XCTAssertEqual(service.snapshotLifetime(background: false), WindowDiscovery.activeSnapshotLifetime)
        XCTAssertEqual(service.snapshotLifetime(background: true), WindowDiscovery.idleSnapshotLifetime)
    }

    func testWaitersWithDifferentKeysNeverLoseTrackOfEachOthersRequests() async {
        let count = DiscoveryCount()
        let gateA = DiscoveryGate()
        let gateC = DiscoveryGate()
        let service = WindowDiscovery(collector: { context in
            await count.add()
            if context.options.excludedBundleIDs.isEmpty { await gateA.wait() }
            if context.options.excludedBundleIDs == ["c"] { await gateC.wait() }
            return Self.collection()
        })
        let a = Task { await service.prepare(context: context()) }
        await waitUntil("A's collector to block on its gate") { await gateA.waiterCount == 1 }
        // Two more callers with two further keys both wait on A.
        let b = Task { await service.prepare(context: context(excluded: ["b"])) }
        let c = Task { await service.prepare(context: context(excluded: ["c"])) }
        await waitUntil("B and C to join A's collection") { service.coalescedRequestCount == 2 }
        await gateA.release()
        await a.value
        // B and C may resume in either order. Do not wait for B before releasing C:
        // if C starts first, B is legitimately queued behind C's closed gate.
        // A fourth caller must share C's collection regardless of that ordering.
        await waitUntil("C's collector to block on its gate") { await gateC.waiterCount == 1 }
        let joinedBeforeD = service.coalescedRequestCount
        let d = Task { await service.prepare(context: context(excluded: ["c"])) }
        await waitUntil("D to join C's collection") { service.coalescedRequestCount == joinedBeforeD + 1 }
        await gateC.release()
        await b.value
        await c.value
        await d.value
        let total = await count.value
        XCTAssertEqual(total, 3, "A, B and C each collect once; D coalesces onto C")
        XCTAssertEqual(service.timeoutCount, 0, "Coalescing must finish without deadline recovery")
    }

    func testCachedTargetMustStillHaveExactWindowServerIDAndOwner() {
        let window = WindowInfo(id: 5, pid: 10, title: "Cached", bounds: .zero, isOnScreen: false)
        func row(_ id: CGWindowID, _ pid: pid_t) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid]
        }
        XCTAssertTrue(WindowFocuser.isWindowPresent(window, lookup: { _ in [row(5, 10)] }))
        XCTAssertFalse(WindowFocuser.isWindowPresent(window, lookup: { _ in [row(6, 10)] }))
        XCTAssertFalse(WindowFocuser.isWindowPresent(window, lookup: { _ in [row(5, 11)] }))
        XCTAssertFalse(WindowFocuser.isWindowPresent(window, lookup: { _ in [] }))
        XCTAssertFalse(WindowFocuser.isWindowPresent(window, lookup: { _ in nil }))
    }
}

private final class DiscoveryClock: @unchecked Sendable {
    var now: TimeInterval = 0
}

private actor DiscoveryCount {
    private(set) var value = 0
    func add() { value += 1 }
}
