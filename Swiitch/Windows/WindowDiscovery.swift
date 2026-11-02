import AppKit

/// Bounded background collection with a short-lived, reusable snapshot. Only immutable
/// app metadata crosses to the worker; focus ordering and display filtering remain local.
@MainActor
final class WindowDiscovery {
    typealias Collector = @Sendable (WindowEnumerator.Context) async -> WindowEnumerator.Collection?
    static let shared = WindowDiscovery()
    private let collector: Collector
    private let now: () -> TimeInterval
    private let contextProvider: @MainActor (EnumerateOptions) -> WindowEnumerator.Context
    private let timeout: TimeInterval
    private let runner = CaptureDeadlineRunner(limit: 1)
    private var inFlight: (id: UInt64, key: Key, eventCount: Int?, activityRevision: UInt64, task: Task<Void, Never>)?
    private var nextRequestID: UInt64 = 0
    private var cacheKey: Key?
    private var cachedEventCount: Int?
    private var collectedAt: TimeInterval = -.infinity
    private var lastUserRequest: TimeInterval = -.infinity
    private var timer: Timer?
    private var started = false
    private var backgroundWorkPaused = false
    private var activityRevision: UInt64 = 0
    var isPollingScheduled: Bool { timer != nil }
    private(set) var lastCollection: WindowEnumerator.Collection?
    private(set) var timeoutCount = 0
    private(set) var cacheHits = 0
    /// Requests that joined a collection already in flight instead of starting their own.
    private(set) var coalescedRequestCount = 0
    /// Durations of the most recent collections, newest last, for Diagnostics percentiles.
    private(set) var recentDurations: [TimeInterval] = []
    static let recentDurationCapacity = 50
    /// When set and active, change notifications drive fresh collections and the periodic
    /// poll only guards against missed events, so background requests accept an older
    /// snapshot. Explicitly forced requests always collect; event refreshes only collect
    /// if that event generation has not already been covered by another request.
    var eventMonitor: WindowEventMonitor?
    /// Delivered only for completed, current collections, never cached/failed reads.
    var onWindowInventory: ((WindowEnumerator.WindowInventory) -> Void)?

    /// A user-facing request (opening the picker, changing a list preference) accepts a
    /// snapshot up to this old.
    nonisolated static let activeSnapshotLifetime: TimeInterval = 1
    /// Background keep-warm requests accept a much older snapshot once the user has been
    /// away from Swiitch for `idleAfter`. Every regular app's AX bridge is queried on each
    /// collection, so idle polling every two seconds was measurable churn for no benefit;
    /// the next user request still gets a fresh collection.
    nonisolated static let idleSnapshotLifetime: TimeInterval = 15
    nonisolated static let idleAfter: TimeInterval = 120
    /// With an event monitor covering every app, a snapshot with no change notification
    /// since is current by construction: both the poll and a user opening the picker may
    /// reuse it this long. Beyond that a collection runs anyway, as a guard against a
    /// notification an app never posted.
    nonisolated static let eventDrivenSnapshotLifetime: TimeInterval = 10
    /// Covered and idle: change notifications invalidate the snapshot the moment they
    /// arrive, so the keep-warm collection is only a guard against a notification an app
    /// never posted. Once a minute is plenty for that, and it is the difference between
    /// waking every regular app's Accessibility bridge four times a minute and once.
    nonisolated static let eventDrivenIdleSnapshotLifetime: TimeInterval = 60

    private struct Key: Equatable {
        let pids: Set<pid_t>
        let excluded: Set<String>
    }

    init(timeout: TimeInterval = 1, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         contextProvider: @escaping @MainActor (EnumerateOptions) -> WindowEnumerator.Context = { WindowEnumerator.context(options: $0) },
         collector: @escaping Collector = { WindowEnumerator.collect(context: $0) }) {
        self.timeout = timeout
        self.now = now
        self.contextProvider = contextProvider
        self.collector = collector
    }

    func start() {
        guard !started else { return }
        started = true
        schedulePolling()
    }

    private func schedulePolling() {
        guard started, !backgroundWorkPaused, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.prepare(options: Self.backgroundOptions()) }
        }
        timer?.tolerance = 0.5
        Task { await prepare(options: Self.backgroundOptions()) }
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
    }

    /// Keep the last snapshot for display, but do not query other apps while asleep or
    /// locked. Resume with a fresh snapshot; reject completions begun before the pause.
    func setBackgroundWorkPaused(_ paused: Bool) {
        guard backgroundWorkPaused != paused else { return }
        backgroundWorkPaused = paused
        activityRevision &+= 1
        cacheKey = nil
        if paused {
            timer?.invalidate()
            timer = nil
        } else {
            schedulePolling()
        }
    }

    private static func backgroundOptions() -> EnumerateOptions {
        EnumerateOptions(isBackgroundRefresh: true, excludedBundleIDs: Set(Preferences.excludedBundleIDs))
    }

    /// How old a snapshot may be for the given kind of request right now.
    func snapshotLifetime(background: Bool) -> TimeInterval {
        let eventDriven = eventMonitor?.coversEveryApp == true
        guard background else { return eventDriven ? Self.eventDrivenSnapshotLifetime : Self.activeSnapshotLifetime }
        if now() - lastUserRequest > Self.idleAfter {
            return eventDriven ? Self.eventDrivenIdleSnapshotLifetime : Self.idleSnapshotLifetime
        }
        return eventDriven ? Self.eventDrivenSnapshotLifetime : Self.activeSnapshotLifetime
    }

    /// eventCount already invalidates stale snapshots. Reuse a collection begun after
    /// that event (or join one in flight), e.g. when the picker beat the background delay.
    /// Without an active monitor there is no event generation, so retain a forced refresh.
    func refreshAfterChange() async {
        await prepare(options: EnumerateOptions(forceRefresh: eventMonitor?.isActive != true, isBackgroundRefresh: true,
                                                excludedBundleIDs: Set(Preferences.excludedBundleIDs)))
    }

    func prepare(options: EnumerateOptions) async {
        guard !options.isBackgroundRefresh || !backgroundWorkPaused else { return }
        if !options.isBackgroundRefresh { lastUserRequest = now() }
        // Cache all Spaces/displays together so pointer movement doesn't trigger a full
        // AX pass. Exclusions still take effect before querying any excluded application.
        let context = contextProvider(.init(excludedBundleIDs: options.excludedBundleIDs))
        await prepare(context: context, force: options.forceRefresh, background: options.isBackgroundRefresh)
    }

    func prepare(context: WindowEnumerator.Context, force: Bool = false, background: Bool = false) async {
        let requestRevision = activityRevision
        let key = Key(pids: Set(context.applications.map(\.processIdentifier)), excluded: context.options.excludedBundleIDs)
        // Several callers can wake from the same in-flight request with different keys.
        // Re-check the cache and whatever is in flight after every wait, so a caller never
        // starts a collection that another waiter has already started for the same key.
        while true {
            guard !background || (!backgroundWorkPaused && requestRevision == activityRevision) else { return }
            if !force, cacheKey == key, lastCollection != nil,
               cachedEventCount == eventMonitor?.eventCount,
               now() - collectedAt < snapshotLifetime(background: background) {
                cacheHits += 1
                return
            }
            guard let inFlight else { break }
            let sameRequest = inFlight.key == key
            coalescedRequestCount += 1
            await inFlight.task.value
            if Task.isCancelled { return }
            // A failed collection is bounded too. Only an event newer than the request
            // requires another collection before this waiter can reuse its result.
            if sameRequest && !force && inFlight.eventCount == eventMonitor?.eventCount
                && inFlight.activityRevision == activityRevision { return }
        }
        guard !Task.isCancelled else { return }
        let collector = self.collector
        let timeout = self.timeout
        nextRequestID &+= 1
        let id = nextRequestID
        let eventCountAtStart = eventMonitor?.eventCount
        let revision = activityRevision
        // Hand the previous collection's Accessibility reads to the next one so an app
        // whose bridge is momentarily slow keeps its ghost-window filtering.
        var context = context
        context.accessibilityMemory = lastCollection?.accessibilityMemory ?? [:]
        let task = Task { [weak self, runner, context] in
            guard let self else { return }
            // A pause can arrive after prepare queued this task but before it ran.
            guard !background || (!self.backgroundWorkPaused && revision == self.activityRevision) else {
                if self.inFlight?.id == id { self.inFlight = nil }
                return
            }
            let result = await runner.run(timeout: timeout) { await collector(context) }
            if let result, revision == self.activityRevision {
                self.lastCollection = result
                self.cacheKey = key
                self.collectedAt = self.now()
                self.cachedEventCount = eventCountAtStart
                self.recentDurations.append(result.duration)
                if self.recentDurations.count > Self.recentDurationCapacity {
                    self.recentDurations.removeFirst(self.recentDurations.count - Self.recentDurationCapacity)
                }
                self.eventMonitor?.reconcile(with: result, applicationPIDs: key.pids)
                if let inventory = result.inventory { self.onWindowInventory?(inventory) }
            } else if result == nil {
                self.timeoutCount += 1
            }
            // Only clear our own handle: a later request with a different key may already
            // be in flight, and a third caller must still be able to coalesce onto it.
            if self.inFlight?.id == id { self.inFlight = nil }
        }
        inFlight = (id, key, eventCountAtStart, revision, task)
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
