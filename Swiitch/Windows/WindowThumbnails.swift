import AppKit
import ScreenCaptureKit
import os

typealias ThumbnailProgressHandler = @MainActor @Sendable (CGWindowID, NSImage) -> Void
typealias ThumbnailCaptureDelivery = @Sendable (CGWindowID, NSImage?) async -> Void
typealias ThumbnailCaptureProvider = @Sendable (
    [CGWindowID],
    ThumbnailCaptureDelivery
) async -> Void

/// Shared by a window's cache entry, capture, and queued UI deliveries. Revocation must
/// remain visible across actor hops without retaining an ever-growing window-ID registry.
private final class ThumbnailGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

private actor ThumbnailCapturePromise {
    private var isResolved = false
    private var image: NSImage?
    private var waiters: [CheckedContinuation<NSImage?, Never>] = []

    func value() async -> NSImage? {
        if isResolved { return image }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resolve(_ image: NSImage?) {
        guard !isResolved else { return }
        isResolved = true
        self.image = image
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume(returning: image)
        }
    }
}

/// Batched window image capture with a bounded in-memory cache.
///
/// Capture path:
///   1. ScreenCaptureKit (macOS 14+) — sharp, supports live + off-screen windows when
///      ScreenCaptureKit can resolve them.
///   2. `CGWindowListCreateImage` — only path that works for minimized windows or
///      windows on inactive Spaces that ScreenCaptureKit refuses. Deprecated in
///      macOS 14 but functional; the deprecation warning is expected.
///
/// Implemented as an `actor` so the cache + in-flight bookkeeping is automatically
/// serialized — callers from any context can safely `await` an image.
@available(macOS 14.0, *)
actor WindowThumbnails {
    static let shared = WindowThumbnails(permissionCheck: { CGPreflightScreenCaptureAccess() })
    private static let nativeCaptures = CaptureDeadlineRunner()

    private struct CacheEntry {
        let image: NSImage
        let byteCost: Int
        let capturedAt: TimeInterval
        let generation: ThumbnailGeneration
        var accessOrder: UInt64
    }

    private struct InFlightCapture {
        let token: UInt64
        let promise: ThumbnailCapturePromise
        let generation: ThumbnailGeneration
    }

    private static let cacheCountLimit = 80
    private static let cacheByteLimit = 96 * 1_024 * 1_024
    private static let maximumPixelDimension = 720
    private static let maximumConcurrentCaptures = 3

    private static let log = Logger(subsystem: "com.swiitch.Swiitch", category: "snapshot")
    private static let liveCaptureProvider: ThumbnailCaptureProvider = { windowIDs, deliver in
        await WindowThumbnails.captureWindows(windowIDs: windowIDs, deliver: deliver)
    }
    private let captureProvider: ThumbnailCaptureProvider
    private let now: @Sendable () -> TimeInterval
    private let permissionCheck: @Sendable () -> Bool
    private let captureTimeout: TimeInterval
    private let retryDelay: TimeInterval
    private var captureAllowed = true
    private var deadlines: [UInt64: Task<Void, Never>] = [:]
    private struct Failure {
        let count: Int
        let retryAfter: TimeInterval
    }
    private var failures: [CGWindowID: Failure] = [:]
    private var images: [CGWindowID: CacheEntry] = [:]
    private var inFlight: [CGWindowID: InFlightCapture] = [:]
    private var captureTasks: [UInt64: Task<Void, Never>] = [:]
    private var totalByteCost = 0
    private var accessOrder: UInt64 = 0
    private var captureToken: UInt64 = 0
    private var timeoutCount = 0
    private var failureCount = 0
    private var cacheHitCount = 0
    private var cacheMissCount = 0
    private var cacheEvictionCount = 0

    /// Aggregate-only diagnostics. Never expose window IDs, images, titles, or URLs.
    struct Statistics: Codable {
        let cachedImages: Int
        let cacheBytes: Int
        let pendingWindows: Int
        let activeBatches: Int
        let backoffWindows: Int
        let timedOutBatches: Int
        let failedCaptures: Int
        /// Lifetime lookups, once per unique requested window. A stale hit may still refresh.
        let cacheHits: Int
        let cacheMisses: Int
        /// Capacity removals only; closing windows, pruning, and permission clears do not count.
        let cacheEvictions: Int
    }

    var statistics: Statistics {
        Statistics(cachedImages: images.count, cacheBytes: totalByteCost,
                   pendingWindows: inFlight.count, activeBatches: captureTasks.count,
                   backoffWindows: failures.count, timedOutBatches: timeoutCount, failedCaptures: failureCount,
                   cacheHits: cacheHitCount, cacheMisses: cacheMissCount, cacheEvictions: cacheEvictionCount)
    }

    init(
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        permissionCheck: @escaping @Sendable () -> Bool = { true },
        captureTimeout: TimeInterval = 8,
        retryDelay: TimeInterval = 2,
        captureProvider: @escaping ThumbnailCaptureProvider = WindowThumbnails.liveCaptureProvider
    ) {
        self.now = now
        self.permissionCheck = permissionCheck
        self.captureTimeout = max(0.001, captureTimeout)
        self.retryDelay = max(0, retryDelay)
        self.captureProvider = captureProvider
    }

    /// Captures a complete set with one ScreenCaptureKit content lookup. Captures run in
    /// small groups so opening Swiitch with many windows cannot create an unbounded burst
    /// of GPU work or full-window image allocations.
    func images(
        for windowIDs: [CGWindowID],
        fresh: Bool = false,
        maximumAge: TimeInterval = 3,
        onUpdate: ThumbnailProgressHandler? = nil
    ) async -> [CGWindowID: NSImage] {
        guard captureAllowed, permissionCheck() else {
            await clear()
            return [:]
        }
        var result: [CGWindowID: NSImage] = [:]
        var generations: [CGWindowID: ThumbnailGeneration] = [:]
        var requests: [(CGWindowID, ThumbnailCapturePromise)] = []
        var newCaptureIDs: [CGWindowID] = []
        var seen: Set<CGWindowID> = []

        for windowID in windowIDs where seen.insert(windowID).inserted {
            let cached = cachedEntryAndTouch(for: windowID)
            if cached == nil { cacheMissCount += 1 }
            else { cacheHitCount += 1 }
            if let cached {
                result[windowID] = cached.image
                generations[windowID] = cached.generation
                if !fresh, max(0, now() - cached.capturedAt) < maximumAge { continue }
            }
            if let existing = inFlight[windowID] {
                generations[windowID] = existing.generation
                requests.append((windowID, existing.promise))
            } else if now() >= (failures[windowID]?.retryAfter ?? -.infinity) {
                let promise = ThumbnailCapturePromise()
                generations[windowID] = cached?.generation ?? ThumbnailGeneration()
                requests.append((windowID, promise))
                newCaptureIDs.append(windowID)
            }
        }

        if !newCaptureIDs.isEmpty {
            captureToken &+= 1
            let token = captureToken
            let newCaptureIDSet = Set(newCaptureIDs)
            for (windowID, promise) in requests where newCaptureIDSet.contains(windowID) {
                inFlight[windowID] = InFlightCapture(token: token, promise: promise, generation: generations[windowID]!)
            }
            if captureTasks.count < 2 {
                startCapture(windowIDs: newCaptureIDs, token: token)
            } else {
                // Two non-cooperative providers may still be returning from cancellation.
                // Fail this request promptly instead of accumulating unbounded workers.
                await finishCaptureBatch(windowIDs: newCaptureIDs, token: token)
            }
        }

        // Register every new promise before the first suspension point. Otherwise another
        // actor call could slip in while cached progress is delivered and start a duplicate
        // capture for the same uncached window.
        if let onUpdate {
            let cached = result.compactMap { windowID, image in
                generations[windowID].map { (windowID, image, $0) }
            }
            // Restore the warm set in one main-actor turn. A separate actor hop for
            // each image can let the grid paint a partially restored cache.
            await MainActor.run {
                for (windowID, image, generation) in cached {
                    if generation.isValid { onUpdate(windowID, image) }
                }
            }
        }

        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for (windowID, promise) in requests {
                group.addTask {
                    (windowID, await promise.value())
                }
            }
            for await (windowID, image) in group {
                guard let image, let generation = generations[windowID], generation.isValid else { continue }
                result[windowID] = image
                if let onUpdate {
                    await MainActor.run {
                        if generation.isValid { onUpdate(windowID, image) }
                    }
                }
            }
        }
        return result.filter { generations[$0.key]?.isValid == true }
    }

    /// Foreground presentation calls this before requesting thumbnails. It cancels background
    /// prewarming work and resolves its waiters, allowing the visible request to start a fresh,
    /// user-initiated capture immediately instead of sitting behind a large hidden batch.
    func cancelPendingCaptures() async {
        let tasks = Array(captureTasks.values)
        // Retain cancelled workers until they really finish, so hangs consume a bounded slot.
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let captures = Array(inFlight.values)
        inFlight.removeAll()
        for task in tasks {
            task.cancel()
        }
        for capture in captures {
            await capture.promise.resolve(nil)
        }
    }

    /// Revoke cached, pending, and queued deliveries together. A late capture cannot
    /// repopulate an invalidated image or become the result of a newer request.
    func invalidate(_ windowID: CGWindowID) async {
        failures.removeValue(forKey: windowID)
        images[windowID]?.generation.invalidate()
        removeCachedImage(for: windowID)
        if let capture = inFlight.removeValue(forKey: windowID) {
            capture.generation.invalidate()
            if !inFlight.values.contains(where: { $0.token == capture.token }) {
                captureTasks[capture.token]?.cancel()
                deadlines.removeValue(forKey: capture.token)?.cancel()
            }
            await capture.promise.resolve(nil)
        }
    }

    /// Drop cached entries whose windows no longer exist. Driven by the model's
    /// prewarm pass so the cache doesn't accumulate stale CGWindowIDs forever.
    func retain(only liveIDs: Set<CGWindowID>) async {
        let staleIDs = Set(images.keys).union(inFlight.keys).union(failures.keys).subtracting(liveIDs)
        for windowID in staleIDs {
            await invalidate(windowID)
        }
    }

    /// Wipe everything. Used if Screen Recording permission is revoked or if we want
    /// a clean slate.
    func clear() async {
        for entry in images.values { entry.generation.invalidate() }
        for capture in inFlight.values { capture.generation.invalidate() }
        images.removeAll()
        failures.removeAll()
        totalByteCost = 0
        await cancelPendingCaptures()
    }

    /// Called on Screen Recording transitions. Denial never prompts and revokes cached
    /// and pending results; a later grant makes failed windows eligible immediately.
    func setCaptureAllowed(_ allowed: Bool) async {
        captureAllowed = allowed
        if !allowed { await clear() }
        else { failures.removeAll() }
    }

    private func store(_ image: NSImage, for windowID: CGWindowID, generation: ThumbnailGeneration) {
        if let previous = images[windowID] {
            totalByteCost -= previous.byteCost
        }
        accessOrder &+= 1
        let byteCost = estimatedByteCost(of: image)
        images[windowID] = CacheEntry(
            image: image,
            byteCost: byteCost,
            capturedAt: now(),
            generation: generation,
            accessOrder: accessOrder
        )
        totalByteCost += byteCost

        while images.count > Self.cacheCountLimit || totalByteCost > Self.cacheByteLimit {
            guard let oldest = images.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key else {
                break
            }
            removeCachedImage(for: oldest)
            cacheEvictionCount += 1
        }
    }

    private func cachedEntryAndTouch(for windowID: CGWindowID) -> CacheEntry? {
        guard var entry = images[windowID] else { return nil }
        accessOrder &+= 1
        entry.accessOrder = accessOrder
        images[windowID] = entry
        return entry
    }

    private func removeCachedImage(for windowID: CGWindowID) {
        guard let removed = images.removeValue(forKey: windowID) else { return }
        totalByteCost = max(0, totalByteCost - removed.byteCost)
    }

    private func estimatedByteCost(of image: NSImage) -> Int {
        if let representation = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }) {
            return max(1, representation.pixelsWide) * max(1, representation.pixelsHigh) * 4
        }
        return max(1, Int(image.size.width)) * max(1, Int(image.size.height)) * 4
    }

    private func startCapture(windowIDs: [CGWindowID], token: UInt64) {
        let provider = captureProvider
        let task = Task(priority: .userInitiated) { [weak self] in
            await provider(windowIDs) { [weak self] windowID, image in
                await self?.finishCapture(windowID: windowID, image: image, token: token)
            }
            await self?.finishCaptureBatch(windowIDs: windowIDs, token: token)
        }
        captureTasks[token] = task
        let timeout = captureTimeout
        deadlines[token] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            guard let self else { return }
            await self.expireCapture(windowIDs: windowIDs, token: token)
        }
    }

    private func expireCapture(windowIDs: [CGWindowID], token: UInt64) async {
        timeoutCount += 1
        captureTasks[token]?.cancel()
        deadlines.removeValue(forKey: token)
        await resolveUnfinished(windowIDs: windowIDs, token: token)
    }

    private func finishCapture(windowID: CGWindowID, image: NSImage?, token: UInt64) async {
        guard let capture = inFlight[windowID], capture.token == token else { return }
        guard captureAllowed, permissionCheck() else { await clear(); return }
        inFlight.removeValue(forKey: windowID)
        if let image, capture.generation.isValid {
            failures.removeValue(forKey: windowID)
            store(image, for: windowID, generation: capture.generation)
        } else {
            recordFailure(windowID)
        }
        await capture.promise.resolve(image)
    }

    private func finishCaptureBatch(windowIDs: [CGWindowID], token: UInt64) async {
        captureTasks.removeValue(forKey: token)
        deadlines.removeValue(forKey: token)?.cancel()
        await resolveUnfinished(windowIDs: windowIDs, token: token)
    }

    private func resolveUnfinished(windowIDs: [CGWindowID], token: UInt64) async {
        let unresolved = windowIDs.compactMap { windowID -> ThumbnailCapturePromise? in
            guard let capture = inFlight[windowID], capture.token == token else { return nil }
            inFlight.removeValue(forKey: windowID)
            recordFailure(windowID)
            return capture.promise
        }
        for promise in unresolved {
            await promise.resolve(nil)
        }
    }

    private func recordFailure(_ windowID: CGWindowID) {
        failureCount += 1
        let count = min(5, (failures[windowID]?.count ?? 0) + 1)
        failures[windowID] = Failure(count: count, retryAfter: now() + min(30, retryDelay * pow(2, Double(count - 1))))
        // Keep retry metadata bounded independently of the image LRU.
        if failures.count > 160,
           let oldest = failures.min(by: { $0.value.retryAfter < $1.value.retryAfter })?.key {
            failures.removeValue(forKey: oldest)
        }
    }

    private nonisolated static func captureWindows(
        windowIDs: [CGWindowID],
        deliver: ThumbnailCaptureDelivery
    ) async {
        var successfulIDs: Set<CGWindowID> = []

        guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return }
        let content: SCShareableContent? = await nativeCaptures.run(timeout: 2) {
            guard CGPreflightScreenCaptureAccess() else { return nil }
            // Include off-screen windows so we can grab thumbnails for things the user
            // isn't currently looking at (other Spaces, etc.).
            return try? await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        }
        if let content {
            let requested = Set(windowIDs)
            let targetsByID = Dictionary(
                uniqueKeysWithValues: content.windows.compactMap { window in
                    requested.contains(window.windowID) ? (window.windowID, window) : nil
                }
            )
            let targets = windowIDs.compactMap { targetsByID[$0] }

            for start in stride(from: 0, to: targets.count, by: Self.maximumConcurrentCaptures) {
                guard !Task.isCancelled else { return }
                let end = min(start + Self.maximumConcurrentCaptures, targets.count)
                let batch = Array(targets[start..<end])
                await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                    for target in batch {
                        group.addTask {
                            (target.windowID, await Self.captureWithRetry(target: target))
                        }
                    }
                    for await (windowID, image) in group {
                        guard let image, let thumbnail = thumbnailImage(from: image) else { continue }
                        successfulIDs.insert(windowID)
                        await deliver(windowID, thumbnail)
                    }
                }
            }
        }

        for windowID in windowIDs where !successfulIDs.contains(windowID) {
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return }
            var image = await boundedCoreGraphicsCapture(windowID: windowID)
            if image == nil {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                image = await boundedCoreGraphicsCapture(windowID: windowID)
            }
            if image == nil {
                log.debug("Both thumbnail capture paths failed for window \(windowID, privacy: .public)")
            }
            await deliver(windowID, image)
        }
    }

    private nonisolated static func captureWithRetry(target: SCWindow) async -> CGImage? {
        if let image = await capture(target: target) {
            return image
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return nil }
        return await capture(target: target)
    }

    private nonisolated static func capture(target: SCWindow) async -> CGImage? {
        await nativeCaptures.run(timeout: 1.5) {
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let size = thumbnailPixelSize(for: target.frame.size)
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.showsCursor = false
            return try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        }
    }

    private nonisolated static func boundedCoreGraphicsCapture(windowID: CGWindowID) async -> NSImage? {
        await nativeCaptures.run(timeout: 1) {
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return nil }
            return captureUsingCoreGraphics(windowID: windowID)
        }
    }

    nonisolated static func thumbnailPixelSize(
        for sourceSize: CGSize,
        maximumDimension: Int = maximumPixelDimension
    ) -> CGSize {
        let width = max(1, sourceSize.width)
        let height = max(1, sourceSize.height)
        let scale = min(1, CGFloat(maximumDimension) / max(width, height))
        return CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )
    }

    private nonisolated static func captureUsingCoreGraphics(windowID: CGWindowID) -> NSImage? {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            options
        ) else {
            return nil
        }
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        return Self.thumbnailImage(from: cgImage)
    }

    /// Enforce the returned bitmap's dimensions, not just the size requested from
    /// ScreenCaptureKit. Both native capture paths must pass through this boundary
    /// before images reach the cache or UI. The 8-bit bitmap also bounds byte cost.
    nonisolated static func thumbnailImage(from cgImage: CGImage) -> NSImage? {
        let size = thumbnailPixelSize(
            for: CGSize(width: cgImage.width, height: cgImage.height)
        )
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return nsImage(from: scaled)
    }

    private nonisolated static func nsImage(from cgImage: CGImage) -> NSImage {
        // NSImage(cgImage:size:) may create a display-scaled backing representation
        // (e.g. 1440 pixels for a 720-point image on Retina). Keep the actual bitmap
        // explicitly so both retained pixels and cache accounting stay bounded.
        let representation = NSBitmapImageRep(cgImage: cgImage)
        let image = NSImage(size: NSSize(width: cgImage.width, height: cgImage.height))
        image.addRepresentation(representation)
        return image
    }
}
