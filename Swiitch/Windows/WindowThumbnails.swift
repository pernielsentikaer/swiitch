import AppKit
import ScreenCaptureKit
import os

/// Per-window image capture with an in-memory cache.
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
    static let shared = WindowThumbnails()

    private static let cacheLimit = 80

    private let log = Logger(subsystem: "com.swiitch.Swiitch", category: "snapshot")
    private var images: [CGWindowID: NSImage] = [:]
    private var pending: Set<CGWindowID> = []

    /// Returns whatever's cached without triggering a capture. Useful for synchronous
    /// SwiftUI reads.
    func cachedImage(for windowID: CGWindowID) -> NSImage? {
        images[windowID]
    }

    /// Returns the cached image, capturing it first if it's missing — or forcing a
    /// fresh capture when `fresh == true`. Concurrent calls for the same window
    /// fold into the first request so we never start two captures for the same id.
    func image(for windowID: CGWindowID, fresh: Bool = false) async -> NSImage? {
        if !fresh, let cached = images[windowID] {
            return cached
        }
        if pending.contains(windowID) {
            return images[windowID]
        }
        pending.insert(windowID)
        defer { pending.remove(windowID) }

        if let captured = await captureUsingScreenCaptureKit(windowID: windowID) {
            store(captured, for: windowID)
            return captured
        }
        if let captured = captureUsingCoreGraphics(windowID: windowID) {
            store(captured, for: windowID)
            return captured
        }
        return nil
    }

    /// Drop a specific window's cached image. Called from the model when it knows
    /// a window has gone away (e.g. user closed it via ⌘W).
    func invalidate(_ windowID: CGWindowID) {
        images.removeValue(forKey: windowID)
    }

    /// Drop cached entries whose windows no longer exist. Driven by the model's
    /// prewarm pass so the cache doesn't accumulate stale CGWindowIDs forever.
    func retain(only liveIDs: Set<CGWindowID>) {
        images = images.filter { liveIDs.contains($0.key) }
    }

    /// Wipe everything. Used if Screen Recording permission is revoked or if we want
    /// a clean slate.
    func clear() {
        images.removeAll()
    }

    private func store(_ image: NSImage, for windowID: CGWindowID) {
        images[windowID] = image
        guard images.count > Self.cacheLimit else { return }
        // Simple over-cap eviction: drop arbitrary entries until we're back under
        // the limit. We don't track MRU because the prewarm pass + `retain(only:)`
        // already keep things tidy for the common case.
        let overflow = images.count - Self.cacheLimit
        for key in images.keys.prefix(overflow) {
            images.removeValue(forKey: key)
        }
    }

    private func captureUsingScreenCaptureKit(windowID: CGWindowID) async -> NSImage? {
        do {
            // Include off-screen windows so we can grab thumbnails for things the user
            // isn't currently looking at (other Spaces, etc.).
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
            guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let size = target.frame.size
            config.width = max(1, Int(size.width.rounded()))
            config.height = max(1, Int(size.height.rounded()))
            config.showsCursor = false
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return nsImage(from: cgImage)
        } catch {
            // Include the owning bundle id so we can diagnose which app SCK is
            // refusing — useful when the failures cluster around one browser.
            let owner = ownerBundleID(forWindowID: windowID) ?? "unknown"
            log.debug("SCK capture failed for window \(windowID, privacy: .public) (\(owner, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Look up which app owns a CGWindowID, returning its bundle identifier when
    /// known. Used only for diagnostic logging.
    private nonisolated func ownerBundleID(forWindowID windowID: CGWindowID) -> String? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            windowID
        ) as? [[String: Any]],
              let pid = info.first?[kCGWindowOwnerPID as String] as? pid_t,
              let runningApp = NSRunningApplication(processIdentifier: pid)
        else { return nil }
        return runningApp.bundleIdentifier
    }

    private nonisolated func captureUsingCoreGraphics(windowID: CGWindowID) -> NSImage? {
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
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private nonisolated func nsImage(from cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
