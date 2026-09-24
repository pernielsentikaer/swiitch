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
    private var inFlight: (id: UInt64, key: Key, task: Task<Void, Never>)?
    private var nextRequestID: UInt64 = 0
    private var cacheKey: Key?
    private var collectedAt: TimeInterval = -.infinity
    private var lastUserRequest: TimeInterval = -.infinity
    private var timer: Timer?
    private(set) var lastCollection: WindowEnumerator.Collection?
    private(set) var timeoutCount = 0
    private(set) var cacheHits = 0

    /// A user-facing request (opening the picker, changing a list preference) accepts a
    /// snapshot up to this old.
    nonisolated static let activeSnapshotLifetime: TimeInterval = 1
    /// Background keep-warm requests accept a much older snapshot once the user has been
    /// away from Swiitch for `idleAfter`. Every regular app's AX bridge is queried on each
    /// collection, so idle polling every two seconds was measurable churn for no benefit;
    /// the next user request still gets a fresh collection.
    nonisolated static let idleSnapshotLifetime: TimeInterval = 15
    nonisolated static let idleAfter: TimeInterval = 120

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
        EnumerateOptions(isBackgroundRefresh: true, excludedBundleIDs: Set(Preferences.excludedBundleIDs))
    }

    /// How old a snapshot may be for the given kind of request right now.
    func snapshotLifetime(background: Bool) -> TimeInterval {
        guard background, now() - lastUserRequest > Self.idleAfter else { return Self.activeSnapshotLifetime }
        return Self.idleSnapshotLifetime
    }

    func prepare(options: EnumerateOptions) async {
        if !options.isBackgroundRefresh { lastUserRequest = now() }
        // Cache all Spaces/displays together so pointer movement doesn't trigger a full
        // AX pass. Exclusions still take effect before querying any excluded application.
        let context = WindowEnumerator.context(options: .init(excludedBundleIDs: options.excludedBundleIDs))
        await prepare(context: context, force: options.forceRefresh, background: options.isBackgroundRefresh)
    }

    func prepare(context: WindowEnumerator.Context, force: Bool = false, background: Bool = false) async {
        let key = Key(pids: Set(context.applications.map(\.processIdentifier)), excluded: context.options.excludedBundleIDs)
        // Several callers can wake from the same in-flight request with different keys.
        // Re-check the cache and whatever is in flight after every wait, so a caller never
        // starts a collection that another waiter has already started for the same key.
        while true {
            if !force, cacheKey == key, lastCollection != nil, now() - collectedAt < snapshotLifetime(background: background) {
                cacheHits += 1
                return
            }
            guard let inFlight else { break }
            let sameRequest = inFlight.key == key
            await inFlight.task.value
            if (sameRequest && !force) || Task.isCancelled { return }
        }
        guard !Task.isCancelled else { return }
        let collector = self.collector
        let timeout = self.timeout
        nextRequestID &+= 1
        let id = nextRequestID
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
            // Only clear our own handle: a later request with a different key may already
            // be in flight, and a third caller must still be able to coalesce onto it.
            if self.inFlight?.id == id { self.inFlight = nil }
        }
        inFlight = (id, key, task)
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
