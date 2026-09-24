import CoreGraphics
@testable import Swiitch
import XCTest

final class ShareableContentCacheTests: XCTestCase {
    private struct Listing: Equatable { let ids: Set<CGWindowID>; let serial: Int }

    private final class Clock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    func testFreshListingCoveringTheRequestIsReused() async {
        let clock = Clock()
        let cache = ShareableContentCache<Listing>(ttl: 1, clock: { clock.now }, windowIDs: \.ids)
        let first = await cache.content(covering: [1, 2]) { Listing(ids: [1, 2, 3], serial: 1) }
        let second = await cache.content(covering: [3]) { Listing(ids: [3], serial: 2) }
        XCTAssertEqual(first, second, "A fresh listing that knows the requested windows is reused")
        let fetches = await cache.fetchCount
        XCTAssertEqual(fetches, 1)
    }

    func testUnknownWindowAndExpiryForceANewListing() async {
        let clock = Clock()
        let cache = ShareableContentCache<Listing>(ttl: 1, clock: { clock.now }, windowIDs: \.ids)
        _ = await cache.content(covering: [1]) { Listing(ids: [1], serial: 1) }
        let unknown = await cache.content(covering: [9]) { Listing(ids: [1, 9], serial: 2) }
        XCTAssertEqual(unknown?.serial, 2, "A window the listing does not know must not be served from cache")
        clock.now = 1.5
        let expired = await cache.content(covering: [1]) { Listing(ids: [1], serial: 3) }
        XCTAssertEqual(expired?.serial, 3, "An expired listing is refreshed")
        let fetches = await cache.fetchCount
        XCTAssertEqual(fetches, 3)
    }

    func testFailedFetchIsNotCached() async {
        let cache = ShareableContentCache<Listing>(ttl: 1, clock: { 0 }, windowIDs: \.ids)
        let failed = await cache.content(covering: [1]) { nil }
        XCTAssertNil(failed)
        let recovered = await cache.content(covering: [1]) { Listing(ids: [1], serial: 1) }
        XCTAssertEqual(recovered?.serial, 1)
    }

    func testConcurrentCallersShareOneInFlightFetch() async {
        let cache = ShareableContentCache<Listing>(ttl: 1, clock: { 0 }, windowIDs: \.ids)
        let gate = FetchGate()
        async let a = cache.content(covering: [1]) { await gate.wait(); return Listing(ids: [1, 2], serial: 1) }
        try? await Task.sleep(for: .milliseconds(30))
        async let b = cache.content(covering: [2]) { Listing(ids: [2], serial: 2) }
        try? await Task.sleep(for: .milliseconds(30))
        await gate.release()
        let (first, second) = await (a, b)
        XCTAssertEqual(first?.serial, 1)
        XCTAssertEqual(second?.serial, 1, "The second caller waits for and reuses the in-flight listing")
        let fetches = await cache.fetchCount
        XCTAssertEqual(fetches, 1)
    }

    func testConcurrentNewWindowsShareOneFollowUpFetch() async {
        let cache = ShareableContentCache<Listing>(ttl: 1, clock: { 0 }, windowIDs: \.ids)
        let firstGate = FetchGate()
        let nextGate = FetchGate()
        async let first = cache.content(covering: [1]) {
            await firstGate.wait()
            return Listing(ids: [1], serial: 1)
        }
        try? await Task.sleep(for: .milliseconds(30))
        async let second = cache.content(covering: [9]) {
            await nextGate.wait()
            return Listing(ids: [1, 9], serial: 2)
        }
        async let third = cache.content(covering: [9]) {
            await nextGate.wait()
            return Listing(ids: [1, 9], serial: 2)
        }
        try? await Task.sleep(for: .milliseconds(30))
        await firstGate.release()
        try? await Task.sleep(for: .milliseconds(30))
        await nextGate.release()
        let (a, b, c) = await (first, second, third)
        XCTAssertEqual(a?.serial, 1)
        XCTAssertEqual(b?.serial, 2)
        XCTAssertEqual(c?.serial, 2)
        let fetches = await cache.fetchCount
        XCTAssertEqual(fetches, 2, "Waiters missing a newly created window must coalesce the follow-up listing")
    }
}

private actor FetchGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
}
