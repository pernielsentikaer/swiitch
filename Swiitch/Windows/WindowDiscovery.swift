import AppKit

/// Bounded background collection with a short-lived, reusable snapshot. Only immutable
/// app metadata crosses to the worker; focus ordering and display filtering remain local.
@MainActor
final class WindowDiscovery {
    typealias Collector = @Sendable (WindowEnumerator.Context) async -> WindowEnumerator.Collection?
    static let shared = WindowDiscovery()
    private let collector: Collector
    private let now: () -> TimeInterval
    private let timeout: TimeInterval
    private let runner = CaptureDeadlineRunner(limit: 1)
    private var inFlight: Task<Void, Never>?
    private var inFlightKey: Key?
    private var cacheKey: Key?
    private var collectedAt: TimeInterval = -.infinity
    private var timer: Timer?
    private(set) var lastCollection: WindowEnumerator.Collection?
    private(set) var timeoutCount = 0
    private(set) var cacheHits = 0

    private struct Key: Equatable {
        let pids: Set<pid_t>
        let excluded: Set<String>
    }

    init(timeout: TimeInterval = 1, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         collector: @escaping Collector = { WindowEnumerator.collect(context: $0) }) {
        self.timeout = timeout
        self.now = now
        self.collector = collector
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.prepare(options: Self.backgroundOptions()) }
        }
        Task { await prepare(options: Self.backgroundOptions()) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private static func backgroundOptions() -> EnumerateOptions {
        EnumerateOptions(excludedBundleIDs: Set(Preferences.excludedBundleIDs))
    }

    func prepare(options: EnumerateOptions) async {
        // Cache all Spaces/displays together so pointer movement doesn't trigger a full
        // AX pass. Exclusions still take effect before querying any excluded application.
        let context = WindowEnumerator.context(options: .init(excludedBundleIDs: options.excludedBundleIDs))
        await prepare(context: context, force: options.forceRefresh)
    }

    func prepare(context: WindowEnumerator.Context, force: Bool = false) async {
        let key = Key(pids: Set(context.applications.map(\.processIdentifier)), excluded: context.options.excludedBundleIDs)
        if !force, cacheKey == key, lastCollection != nil, now() - collectedAt < 1 {
            cacheHits += 1
            return
        }
        if let task = inFlight {
            let sameRequest = inFlightKey == key
            await task.value
            if (sameRequest && !force) || Task.isCancelled { return }
        }
        guard !Task.isCancelled else { return }
        let collector = self.collector
        let timeout = self.timeout
        inFlightKey = key
        let task = Task { [weak self, runner] in
            let result = await runner.run(timeout: timeout) { await collector(context) }
            guard let self else { return }
            if let result {
                self.lastCollection = result
                self.cacheKey = key
                self.collectedAt = self.now()
            } else {
                self.timeoutCount += 1
            }
            self.inFlight = nil
            self.inFlightKey = nil
        }
        inFlight = task
        await task.value
    }

    func entries(focusTracker: FocusTracker, options: EnumerateOptions) -> [AppEntry] {
        let screen = options.restrictToActiveScreen ? WindowEnumerator.activeScreenCGFrame() : nil
        let apps = Self.filtered(lastCollection?.apps ?? [], options: options, screenFrame: screen)
        return WindowEnumerator.ordered(apps, focusTracker: focusTracker)
    }

    static func filtered(_ apps: [AppEntry], options: EnumerateOptions, screenFrame: CGRect?) -> [AppEntry] {
        apps.compactMap { entry in
            guard !options.excludedBundleIDs.contains(entry.bundleIdentifier ?? "") else { return nil }
            var app = entry
            app.windows = app.windows.filter { window in
                options.includes(window)
                    && (screenFrame == nil || screenFrame!.intersects(window.bounds))
            }
            return app.windows.isEmpty ? nil : app
        }
    }
}
