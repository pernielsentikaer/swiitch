import AppKit
@testable import Swiitch
import XCTest

final class ThumbnailFreshnessTests: XCTestCase {
    func testCacheCountersCountUniqueLookupsIncludingStaleAndForcedHits() async {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture()
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1, 1, 2])
        _ = await cache.images(for: [1, 2, 2])
        clock.set(104)
        _ = await cache.images(for: [1])
        _ = await cache.images(for: [2], fresh: true)
        let stats = await cache.statistics
        XCTAssertEqual(stats.cacheHits, 4)
        XCTAssertEqual(stats.cacheMisses, 2)
        XCTAssertEqual(stats.cacheEvictions, 0)
    }

    func testCapacityEvictionsExcludePruningInvalidationAndClearing() async {
        let cache = makeCache(ThumbnailTestClock(), ThumbnailTestCapture())
        _ = await cache.images(for: (1...81).map { CGWindowID($0) })
        let full = await cache.statistics
        XCTAssertEqual(full.cachedImages, 80)
        XCTAssertEqual(full.cacheEvictions, 1)
        await cache.retain(only: [80, 81])
        await cache.invalidate(81)
        await cache.clear()
        let cleared = await cache.statistics
        XCTAssertEqual(cleared.cachedImages, 0)
        XCTAssertEqual(cleared.cacheEvictions, 1)
        XCTAssertEqual(cleared.cacheMisses, 81, "Counters cover the cache's lifetime, not just retained entries")
    }

    func testBytePressureAlsoCountsAsCapacityEviction() async {
        let cache = WindowThumbnails(captureProvider: { ids, deliver in
            for id in ids {
                await deliver(id, NSImage(size: NSSize(width: 2_000, height: 2_000)))
            }
        })
        _ = await cache.images(for: (1...7).map { CGWindowID($0) })
        let stats = await cache.statistics
        XCTAssertEqual(stats.cachedImages, 6)
        XCTAssertEqual(stats.cacheEvictions, 1)
        XCTAssertEqual(stats.cacheMisses, 7)
    }

    func testDeniedRequestsDoNotInflateCacheCounters() async {
        let cache = WindowThumbnails(permissionCheck: { false })
        _ = await cache.images(for: [1, 2, 3])
        let stats = await cache.statistics
        XCTAssertEqual(stats.cacheHits, 0)
        XCTAssertEqual(stats.cacheMisses, 0)
        XCTAssertEqual(stats.cacheEvictions, 0)
    }

    func testReturnedBitmapIsBoundedWithoutUpscaling() throws {
        for (width, height, expectedWidth, expectedHeight) in [
            (2_880, 1_760, 720, 440),
            (1_760, 2_880, 440, 720),
            (120, 80, 120, 80),
        ] {
            let source = try bitmap(width: width, height: height)
            let image = try XCTUnwrap(WindowThumbnails.thumbnailImage(from: source))
            let representation = try XCTUnwrap(image.representations.first)
            XCTAssertTrue(representation is NSBitmapImageRep, "Retain the real bitmap, not a display-scaled snapshot")
            XCTAssertEqual(representation.pixelsWide, expectedWidth)
            XCTAssertEqual(representation.pixelsHigh, expectedHeight)
            XCTAssertEqual(image.size, NSSize(width: expectedWidth, height: expectedHeight))
        }
    }

    func testNormalizedPreviewsKeepThirtyOneWindowsCachedAcrossRepeatedOpenings() async throws {
        let provider = BitmapThumbnailCapture(source: try bitmap(width: 2_880, height: 1_760))
        let cache = WindowThumbnails(captureProvider: { ids, deliver in
            await provider.capture(ids, deliver: deliver)
        })
        let ids = (1...31).map { CGWindowID($0) }
        for _ in 0..<3 {
            let images = await cache.images(for: ids, maximumAge: .infinity)
            XCTAssertEqual(Set(images.keys), Set(ids))
            let stats = await cache.statistics
            XCTAssertEqual(stats.cachedImages, 31)
            XCTAssertEqual(stats.cacheBytes, 31 * 720 * 440 * 4)
            XCTAssertEqual(stats.failedCaptures, 0)
            XCTAssertEqual(stats.cacheEvictions, 0)
        }
        let batches = await provider.batches
        XCTAssertEqual(batches, [ids], "Warm openings must not recapture previews evicted by oversized bitmaps")
    }

    func testWarmCacheIsDeliveredInOneMainActorTurn() async throws {
        let provider = ThumbnailTestCapture()
        let cache = makeCache(ThumbnailTestClock(), provider)
        let ids = (1...12).map { CGWindowID($0) }
        _ = await cache.images(for: ids)
        let recorder = await MainActor.run { ThumbnailBatchRecorder() }
        _ = await cache.images(for: ids) { id, _ in
            recorder.received.append(id)
            Task { @MainActor in
                recorder.countsObservedAfterYield.append(recorder.received.count)
            }
        }
        for _ in 0..<100 {
            if await MainActor.run(body: { recorder.countsObservedAfterYield.count == ids.count }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let received = await MainActor.run { recorder.received }
        let counts = await MainActor.run { recorder.countsObservedAfterYield }
        XCTAssertEqual(Set(received), Set(ids))
        XCTAssertEqual(counts, Array(repeating: ids.count, count: ids.count),
                       "The UI must not get a turn between cached preview deliveries")
    }

    func testFreshCacheIsReusedButReadsDoNotExtendItsLifetime() async {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture()
        let cache = makeCache(clock, provider)
        let first = await cache.images(for: [1])
        clock.set(102)
        let recent = await cache.images(for: [1])
        XCTAssertEqual(first[1]?.size.width, recent[1]?.size.width)
        clock.set(104)
        let refreshed = await cache.images(for: [1])
        XCTAssertEqual(refreshed[1]?.size.width, 102)
        let batches = await provider.batches
        XCTAssertEqual(batches, [[1], [1]])
    }

    func testStaleImageIsDeliveredBeforeRefreshCompletes() async throws {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture(blocked: [2])
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1])
        clock.set(104)
        let recorder = await MainActor.run { ThumbnailImageRecorder() }
        let request = Task {
            await cache.images(for: [1]) { _, image in recorder.widths.append(image.size.width) }
        }
        try await waitForBatch(2, provider)
        for _ in 0..<100 {
            if await MainActor.run(body: { !recorder.widths.isEmpty }) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let partial = await MainActor.run { recorder.widths }
        XCTAssertEqual(partial, [101])
        await provider.release(2)
        let result = await request.value
        XCTAssertEqual(result[1]?.size.width, 102)
        let delivered = await MainActor.run { recorder.widths }
        XCTAssertEqual(delivered, [101, 102])
    }

    func testFailedRefreshKeepsLastGoodImageAndDoesNotRenewItsAge() async {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture(failed: [2])
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1])
        clock.set(104)
        let failed = await cache.images(for: [1])
        XCTAssertEqual(failed[1]?.size.width, 101)
        clock.set(107) // Past the retry backoff; failed captures must not renew image age.
        let retry = await cache.images(for: [1])
        XCTAssertEqual(retry[1]?.size.width, 103)
    }

    func testBackgroundPrewarmDoesNotRefreshExistingImages() async {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture()
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1])
        clock.set(10_000)
        let result = await cache.images(for: [1, 2], maximumAge: .infinity)
        XCTAssertEqual(result[1]?.size.width, 101)
        XCTAssertEqual(result[2]?.size.width, 102)
        let batches = await provider.batches
        XCTAssertEqual(batches, [[1], [2]])
    }

    func testForcedRefreshBypassesFreshCache() async {
        let provider = ThumbnailTestCapture()
        let cache = makeCache(ThumbnailTestClock(), provider)
        _ = await cache.images(for: [1])
        let result = await cache.images(for: [1], fresh: true)
        XCTAssertEqual(result[1]?.size.width, 102)
    }

    func testConcurrentStaleRequestsShareRefresh() async throws {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture(blocked: [2])
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1])
        clock.set(104)
        let first = Task { await cache.images(for: [1]) }
        try await waitForBatch(2, provider)
        let second = Task { await cache.images(for: [1]) }
        await Task.yield()
        await provider.release(2)
        let a = await first.value
        let b = await second.value
        XCTAssertEqual(a[1]?.size.width, 102)
        XCTAssertEqual(b[1]?.size.width, 102)
        let count = await provider.batches.count
        XCTAssertEqual(count, 2)
    }

    func testInvalidatedLateCaptureCannotRepopulateCache() async throws {
        let provider = ThumbnailTestCapture(blocked: [1])
        let cache = makeCache(ThumbnailTestClock(), provider)
        let request = Task { await cache.images(for: [1]) }
        try await waitForBatch(1, provider)
        await cache.invalidate(1)
        await provider.release(1)
        let invalidated = await request.value
        XCTAssertTrue(invalidated.isEmpty)
        let fresh = await cache.images(for: [1])
        XCTAssertEqual(fresh[1]?.size.width, 102)
    }

    func testInvalidationDoesNotCancelOtherWindowsInBatch() async throws {
        let provider = ThumbnailTestCapture(blocked: [1])
        let cache = makeCache(ThumbnailTestClock(), provider)
        let request = Task { await cache.images(for: [1, 2]) }
        try await waitForBatch(1, provider)
        await cache.invalidate(1)
        await provider.release(1)
        let result = await request.value
        XCTAssertEqual(Set(result.keys), [2])
        let cached = await cache.images(for: [2])
        XCTAssertEqual(cached[2]?.size.width, 101)
    }

    func testInvalidateDuringRefreshRevokesCachedFallbackToo() async throws {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture(blocked: [2])
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1])
        clock.set(104)
        let request = Task { await cache.images(for: [1]) }
        try await waitForBatch(2, provider)
        await cache.invalidate(1)
        await provider.release(2)
        let result = await request.value
        XCTAssertTrue(result.isEmpty)
        let next = await cache.images(for: [1])
        XCTAssertEqual(next[1]?.size.width, 103)
    }

    func testRetainPrunesPendingCapturesAsWellAsCache() async throws {
        let provider = ThumbnailTestCapture(blocked: [1])
        let cache = makeCache(ThumbnailTestClock(), provider)
        let request = Task { await cache.images(for: [1, 2]) }
        try await waitForBatch(1, provider)
        await cache.retain(only: [2])
        await provider.release(1)
        let result = await request.value
        XCTAssertEqual(Set(result.keys), [2])
        let next = await cache.images(for: [1, 2])
        XCTAssertEqual(next[1]?.size.width, 102)
        XCTAssertEqual(next[2]?.size.width, 101)
    }

    func testClearRevokesCachedAndInFlightResults() async throws {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture(blocked: [2])
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1])
        clock.set(104)
        let request = Task { await cache.images(for: [1, 2]) }
        try await waitForBatch(2, provider)
        await cache.clear()
        await provider.release(2)
        let result = await request.value
        XCTAssertTrue(result.isEmpty)
        let next = await cache.images(for: [1])
        XCTAssertEqual(next[1]?.size.width, 103)
    }

    func testCancelRefreshKeepsUsableCachedFallback() async throws {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture(blocked: [2])
        let cache = makeCache(clock, provider)
        _ = await cache.images(for: [1])
        clock.set(104)
        let request = Task { await cache.images(for: [1]) }
        try await waitForBatch(2, provider)
        await cache.cancelPendingCaptures()
        await provider.release(2)
        let result = await request.value
        XCTAssertEqual(result[1]?.size.width, 101)
    }

    func testStalledCaptureReturnsWithoutWaitingAndLateResultIsIgnored() async throws {
        let provider = ThumbnailTestCapture(blocked: [1])
        let cache = makeCache(ThumbnailTestClock(), provider, timeout: 0.03, retryDelay: 0)
        let completion = ThumbnailCompletion()
        let request = Task {
            let result = await cache.images(for: [1])
            await completion.complete(result)
        }
        try await waitForBatch(1, provider)
        try await Task.sleep(for: .milliseconds(100))
        let finished = await completion.finished
        XCTAssertTrue(finished, "A non-cooperative capture must not hold its caller indefinitely")
        let next = await cache.images(for: [1])
        XCTAssertEqual(next[1]?.size.width, 102)
        await provider.release(1)
        await request.value
        let cached = await cache.images(for: [1])
        XCTAssertEqual(cached[1]?.size.width, 102)
    }

    func testStalledRefreshRetainsTheLastGoodImage() async throws {
        let provider = ThumbnailTestCapture(blocked: [2])
        let cache = makeCache(ThumbnailTestClock(), provider, timeout: 0.03)
        _ = await cache.images(for: [1])
        let completion = ThumbnailCompletion()
        let request = Task { await completion.complete(await cache.images(for: [1], fresh: true)) }
        try await waitForBatch(2, provider)
        try await Task.sleep(for: .milliseconds(100))
        let finished = await completion.finished
        let width = await completion.images[1]?.size.width
        XCTAssertTrue(finished)
        XCTAssertEqual(width, 101)
        await provider.release(2)
        await request.value
    }

    func testRepeatedStallsCannotAccumulateProviderWorkers() async throws {
        let provider = ThumbnailTestCapture(blocked: [1, 2])
        let cache = makeCache(ThumbnailTestClock(), provider, timeout: 0.02, retryDelay: 0)
        let first = Task { await cache.images(for: [1]) }
        try await waitForBatch(1, provider)
        try await Task.sleep(for: .milliseconds(70))
        let second = Task { await cache.images(for: [2]) }
        try await waitForBatch(2, provider)
        try await Task.sleep(for: .milliseconds(70))
        for id: CGWindowID in 3...12 {
            let result = await cache.images(for: [id])
            XCTAssertTrue(result.isEmpty)
        }
        let batches = await provider.batches.count
        XCTAssertEqual(batches, 2)
        await provider.release(1)
        await provider.release(2)
        _ = await first.value
        _ = await second.value
    }

    func testFailedCapturesUseBoundedExponentialBackoffEvenWhenForced() async {
        let clock = ThumbnailTestClock()
        let provider = ThumbnailTestCapture(failed: [1, 2, 3, 4, 5, 6])
        let cache = makeCache(clock, provider)
        for time: TimeInterval in [100, 102, 106, 114, 130, 160] {
            clock.set(time)
            _ = await cache.images(for: [1], fresh: true)
            let before = await provider.batches.count
            clock.set(time + 1)
            _ = await cache.images(for: [1], fresh: true)
            let after = await provider.batches.count
            XCTAssertEqual(before, after)
        }
        let count = await provider.batches.count
        XCTAssertEqual(count, 6)
        clock.set(190)
        let recovered = await cache.images(for: [1])
        XCTAssertEqual(recovered[1]?.size.width, 107)
    }

    func testPermissionRevocationClearsCacheRejectsLateCaptureAndGrantRetries() async throws {
        let provider = ThumbnailTestCapture(blocked: [2])
        let cache = makeCache(ThumbnailTestClock(), provider)
        _ = await cache.images(for: [1])
        let pending = Task { await cache.images(for: [1, 2], fresh: true) }
        try await waitForBatch(2, provider)
        await cache.setCaptureAllowed(false)
        let denied = await cache.images(for: [1, 2])
        XCTAssertTrue(denied.isEmpty)
        await cache.setCaptureAllowed(true)
        let recovered = await cache.images(for: [1, 2])
        XCTAssertEqual(recovered[1]?.size.width, 103)
        await provider.release(2)
        let obsolete = await pending.value
        XCTAssertTrue(obsolete.isEmpty)
        let cached = await cache.images(for: [1])
        XCTAssertEqual(cached[1]?.size.width, 103)
    }

    func testPermissionPreflightDenialDoesNotStartProvider() async {
        let provider = ThumbnailTestCapture()
        let cache = WindowThumbnails(permissionCheck: { false }, captureProvider: { ids, deliver in
            await provider.capture(ids, deliver: deliver)
        })
        let denied = await cache.images(for: [1])
        let count = await provider.batches.count
        XCTAssertTrue(denied.isEmpty)
        XCTAssertEqual(count, 0)
    }

    private func bitmap(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeCache(_ clock: ThumbnailTestClock, _ capture: ThumbnailTestCapture,
                           timeout: TimeInterval = 8, retryDelay: TimeInterval = 2) -> WindowThumbnails {
        WindowThumbnails(now: { clock.now }, captureTimeout: timeout, retryDelay: retryDelay) { ids, deliver in
            await capture.capture(ids, deliver: deliver)
        }
    }

    private func waitForBatch(_ count: Int, _ provider: ThumbnailTestCapture) async throws {
        for _ in 0..<1000 {
            if await provider.batches.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Capture did not start")
        throw NSError(domain: "ThumbnailTestTimeout", code: 1)
    }
}

/// Models a native capture returning more pixels than requested, without reading the screen.
private actor BitmapThumbnailCapture {
    let source: CGImage
    private(set) var batches: [[CGWindowID]] = []

    init(source: CGImage) { self.source = source }

    func capture(_ ids: [CGWindowID], deliver: ThumbnailCaptureDelivery) async {
        batches.append(ids)
        for id in ids {
            await deliver(id, WindowThumbnails.thumbnailImage(from: source))
        }
    }
}

@MainActor
private final class ThumbnailBatchRecorder {
    var received: [CGWindowID] = []
    var countsObservedAfterYield: [Int] = []
}

private actor ThumbnailCompletion {
    private(set) var finished = false
    private(set) var images: [CGWindowID: NSImage] = [:]
    func complete(_ result: [CGWindowID: NSImage]) { images = result; finished = true }
}

private final class ThumbnailTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
}

private actor ThumbnailTestCapture {
    private(set) var batches: [[CGWindowID]] = []
    private let blocked: Set<Int>
    private let failed: Set<Int>
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(blocked: Set<Int> = [], failed: Set<Int> = []) {
        self.blocked = blocked
        self.failed = failed
    }

    func capture(_ ids: [CGWindowID], deliver: ThumbnailCaptureDelivery) async {
        batches.append(ids)
        let batch = batches.count
        if blocked.contains(batch) {
            await withCheckedContinuation { waiters[batch] = $0 }
        }
        // Intentionally ignores cancellation to model a native capture finishing late.
        let image = failed.contains(batch) ? nil : NSImage(size: NSSize(width: 100 + batch, height: 24))
        for id in ids { await deliver(id, image) }
    }

    func release(_ batch: Int) { waiters.removeValue(forKey: batch)?.resume() }
}

@MainActor
private final class ThumbnailImageRecorder {
    var widths: [CGFloat] = []
}
