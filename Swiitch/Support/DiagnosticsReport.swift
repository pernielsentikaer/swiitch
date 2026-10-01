import AppKit

/// Strictly allowlisted aggregate data. Do not add raw errors, window/app identifiers,
/// titles, paths, URLs, preferences dictionaries, or images to this schema.
enum DiagnosticsReport {
    struct Snapshot: Codable {
        var schemaVersion = 1
        let version: String
        let build: String
        let osVersion: String
        let architecture: String
        let accessibilityGranted: Bool
        /// False means `_AXUIElementGetWindow` did not resolve, so no app's windows can be
        /// matched to Accessibility and the ghost-window filter is effectively off.
        var accessibilityWindowIDsAvailable = true
        /// False means the SkyLight Spaces-membership SPI did not resolve on this macOS.
        var spacesMembershipAvailable = true
        let screenRecordingGranted: Bool
        let keyboardStatus: String
        let loginItemStatus: String
        let automaticUpdateChecks: Bool
        let discovery: Discovery
        let thumbnails: WindowThumbnails.Statistics
        /// Milliseconds from the hotkey to each stage of recent opens; counts and timings only.
        let timing: OpenLatency.Summary
    }

    struct Discovery: Codable {
        let appCount: Int
        let windowCount: Int
        let candidateCount: Int
        let filteredCount: Int
        let unavailableAXAppCount: Int
        /// Apps whose failed read was covered by a recent remembered Accessibility read.
        var reusedAXAppCount = 0
        let lastCollectionMilliseconds: Int?
        /// Percentiles over the most recent collections.
        var collectionMilliseconds: OpenLatency.Percentiles?
        let timeoutCount: Int
        let cacheHits: Int
        let filterReasons: [String: Int]
        /// Change notifications drive collections when true; counts since launch.
        var eventDriven = false
        var eventsCoverEveryApp = false
        var observedAppCount = 0
        var subscribedWindowCount = 0
        var eventCount = 0
        var eventRefreshCount = 0

        init(collection: WindowEnumerator.Collection?, timeoutCount: Int, cacheHits: Int,
             recentDurations: [TimeInterval] = [], events: WindowEventMonitor.Statistics? = nil) {
            appCount = collection?.apps.count ?? 0
            windowCount = collection?.apps.reduce(0) { $0 + $1.windows.count } ?? 0
            candidateCount = collection?.candidateCount ?? 0
            filteredCount = collection?.filteredCount ?? 0
            unavailableAXAppCount = collection?.unavailableAXCount ?? 0
            reusedAXAppCount = collection?.reusedAXCount ?? 0
            if let duration = collection?.duration, duration.isFinite, duration >= 0 {
                lastCollectionMilliseconds = Int(min(duration * 1000, 3_600_000))
            } else { lastCollectionMilliseconds = nil }
            collectionMilliseconds = OpenLatency.Percentiles(
                recentDurations.filter { $0.isFinite && $0 >= 0 }.map { min($0 * 1000, 3_600_000) }
            )
            self.timeoutCount = timeoutCount
            self.cacheHits = cacheHits
            filterReasons = Dictionary(uniqueKeysWithValues: WindowEnumerator.FilterReason.allCases.map {
                ($0.rawValue, collection?.filterReasons[$0] ?? 0)
            })
            if let events {
                eventDriven = events.active
                eventsCoverEveryApp = events.coversEveryApp
                observedAppCount = events.observedApps
                subscribedWindowCount = events.subscribedWindows
                eventCount = events.events
                eventRefreshCount = events.refreshes
            }
        }
    }

    @MainActor static func current() async -> Snapshot {
        let discovery = WindowDiscovery.shared
        LoginItemController.shared.refresh()
        UpdateController.shared.refreshSettings()
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return Snapshot(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            accessibilityGranted: AXIsProcessTrusted(),
            accessibilityWindowIDsAvailable: AXPrivate.windowIDResolverAvailable,
            spacesMembershipAvailable: AXPrivate.spacesResolverAvailable,
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            keyboardStatus: HotkeyStatus.shared.value.rawValue,
            loginItemStatus: LoginItemController.shared.status.rawValue,
            automaticUpdateChecks: UpdateController.shared.automaticChecksEnabled,
            discovery: Discovery(collection: discovery.lastCollection, timeoutCount: discovery.timeoutCount,
                                 cacheHits: discovery.cacheHits, recentDurations: discovery.recentDurations,
                                 events: discovery.eventMonitor?.statistics),
            thumbnails: await WindowThumbnails.shared.statistics,
            timing: OpenLatency.shared.summary
        )
    }

    static func render(_ snapshot: Snapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    }

    /// Clipboard mutation occurs only when the user presses Copy, never during collection.
    @MainActor static func copy(_ report: String, write: (String) -> Bool = {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString($0, forType: .string)
    }) -> Bool { write(report) }
}
