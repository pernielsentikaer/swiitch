import AppKit
import Combine

/// Owns everything about window previews: cached images and per-window states, the
/// Screen Recording flag, the viewport-driven refresh set, the idle prewarm loop, and
/// the epoch/permission protocol that keeps stale captures from landing.
///
/// It never reads the picker's lists or selection directly. `SwitcherModel` hands it a
/// `Scope` snapshot on demand, so every guard here is evaluated against the same
/// invocation, mode, and query that the UI is showing. The main-actor model drives its
/// synchronous lifecycle; async entry points explicitly hop to `@MainActor`.
final class ThumbnailCoordinator: ObservableObject {
    /// What the coordinator needs to know about the picker at one instant.
    struct Scope {
        var isArmed = false
        var generation: UInt64 = 0
        var panelShown = false
        /// Whether the current mode shows previews at all (Apps first does not).
        var loadsThumbnails = false
        /// Windows whose previews may be shown in the current mode (unfiltered).
        var windows: [WindowInfo] = []
        /// Search-filtered subset used for periodic refresh.
        var refreshCandidates: [WindowInfo] = []
        var highlightedWindowID: CGWindowID?
        /// Identity of the layout that reported a viewport; the coordinator adds its epoch.
        var mode: SwitcherModel.Mode = .apps
        var appPID: pid_t?
        var query = ""
    }

    /// Inputs for idle prewarming, which runs while the picker is closed.
    struct PrewarmSource {
        var excludedBundleIDs: () -> Set<String>
        var loadsThumbnails: () -> Bool
        var prepareAllLive: (Set<String>) async -> Void
        var allLiveWindowIDs: (Set<String>) -> Set<CGWindowID>
        var scopedWindowIDs: () -> [CGWindowID]
    }

    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published private(set) var thumbnailStates: [CGWindowID: ThumbnailState] = [:]
    @Published private(set) var screenCaptureGranted: Bool

    /// Bumped on teardown and permission changes so in-flight work cannot deliver.
    private(set) var epoch: UInt64 = 0

    /// Supplied by the owner after construction; returns an idle scope when the owner is gone.
    var scope: () -> Scope = { Scope() }
    var prewarmSource: PrewarmSource?

    private let dependencies: SwitcherModel.Dependencies
    private var viewport: (context: SwitcherModel.ThumbnailViewportContext, ids: Set<CGWindowID>)?
    private var pendingIDs: Set<CGWindowID> = []
    private var permissionRevision: UInt64 = 0
    private var permissionTransition: Task<Void, Never>?
    private var updatingCapturePermission = false
    private var prewarmInFlight = false
    private var prewarmTimer: Timer?
    private var refreshTimer: Timer?

    init(dependencies: SwitcherModel.Dependencies) {
        self.dependencies = dependencies
        screenCaptureGranted = dependencies.screenCaptureGranted()
    }

    deinit {
        prewarmTimer?.invalidate()
        refreshTimer?.invalidate()
    }

    // MARK: - Read

    func state(for id: CGWindowID) -> ThumbnailState {
        if !screenCaptureGranted { return .permissionRequired }
        if thumbnails[id] != nil { return .ready }
        return thumbnailStates[id] ?? .loading
    }

    func viewportContext(for scope: Scope) -> SwitcherModel.ThumbnailViewportContext {
        .init(generation: scope.generation, epoch: epoch, mode: scope.mode,
              appPID: scope.appPID, query: scope.query)
    }

    /// Until layout has reported a viewport, use the search-filtered scope. Once known,
    /// refresh intersecting tiles plus the selected target while it scrolls into view.
    var refreshWindows: [WindowInfo] {
        let scope = self.scope()
        let candidates = scope.refreshCandidates
        guard let viewport, viewport.context == viewportContext(for: scope) else {
            return candidates
        }
        return candidates.filter { viewport.ids.contains($0.id) || $0.id == scope.highlightedWindowID }
    }

    // MARK: - Lifecycle driven by the model

    /// Called once the picker is armed; captures the invocation so a later arm cannot
    /// receive this invocation's images.
    func requestInitial(for windows: [WindowInfo]) {
        let arm = scope().generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let scope = self.scope()
            guard scope.isArmed, scope.generation == arm else { return }
            await self.fetchInitial(for: windows)
        }
    }

    /// A window action changed its content; refresh that tile after the app has redrawn.
    func refreshAfterAction(_ window: WindowInfo) {
        if let invalidateThumbnail = dependencies.invalidateThumbnail {
            Task { await invalidateThumbnail(window.id) }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self?.fetch(for: [window], fresh: true)
        }
    }

    /// Windows that left the picker (closed app, exclusion) drop their previews.
    func remove(windowIDs removed: Set<CGWindowID>) {
        guard !removed.isEmpty else { return }
        thumbnails = thumbnails.filter { !removed.contains($0.key) }
        thumbnailStates = thumbnailStates.filter { !removed.contains($0.key) }
        if let invalidateThumbnail = dependencies.invalidateThumbnail {
            for id in removed {
                Task { await invalidateThumbnail(id) }
            }
        }
    }

    /// Picker teardown: forget per-invocation state and invalidate in-flight deliveries.
    func reset() {
        stopRefreshTimer()
        thumbnails = [:]
        thumbnailStates = [:]
        viewport = nil
        epoch &+= 1
        pendingIDs.removeAll()
    }

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Self.scheduleTimer(interval: 2.0, repeats: true) { [weak self] in
            Task { [weak self] in
                await self?.refreshVisible()
            }
        }
    }

    func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func startPrewarmTimer() {
        prewarmTimer?.invalidate()
        prewarmTimer = Self.scheduleTimer(interval: 4.0, repeats: true) { [weak self] in
            guard let self, !self.scope().isArmed else { return }
            Task { [weak self] in
                await self?.prewarmCache()
            }
        }
    }

    // MARK: - Viewport and refresh

    @MainActor
    func updateViewport(_ ids: Set<CGWindowID>, context: SwitcherModel.ThumbnailViewportContext) {
        let scope = self.scope()
        guard scope.isArmed, context == viewportContext(for: scope) else { return }
        let scopedIDs = ids.intersection(scope.windows.map(\.id))
        let previous = viewport.flatMap { $0.context == context ? $0.ids : nil } ?? []
        viewport = (context, scopedIDs)
        let added = scopedIDs.subtracting(previous)
        guard !added.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let scope = self.scope()
            guard scope.isArmed, self.viewportContext(for: scope) == context else { return }
            let windows = self.refreshWindows.filter { added.contains($0.id) }
            // Reuse cached images immediately; only missing/stale entries need capture.
            await self.fetch(for: windows, fresh: false)
        }
    }

    @MainActor
    func refreshVisible() async {
        let scope = self.scope()
        guard scope.isArmed, scope.panelShown, scope.loadsThumbnails else { return }
        await fetch(for: refreshWindows, fresh: true)
    }

    // MARK: - Permission

    /// UI revocation is immediate. Cache transitions are serialized so rapid deny/grant
    /// changes cannot let an older clear wipe a newer capture. No permission prompt here.
    @MainActor
    func updatePermission(_ granted: Bool) {
        guard screenCaptureGranted != granted else { return }
        screenCaptureGranted = granted
        epoch &+= 1
        pendingIDs.removeAll()
        thumbnails.removeAll()
        thumbnailStates.removeAll()
        permissionRevision &+= 1
        let revision = permissionRevision
        updatingCapturePermission = true
        let previous = permissionTransition
        let updateCache = dependencies.setThumbnailCaptureAllowed
        permissionTransition = Task { @MainActor [weak self] in
            await previous?.value
            await updateCache?(granted)
            guard let self, self.permissionRevision == revision else { return }
            self.updatingCapturePermission = false
            if granted, self.scope().isArmed {
                await self.fetchInitial(for: self.scope().windows)
            }
        }
    }

    // MARK: - Prewarm

    /// Retain every live, non-excluded preview; only capture missing previews in the
    /// current display/Spaces/minimized scope. Both lists are cached discovery reads.
    @MainActor
    func prewarmCache() async {
        guard let source = prewarmSource else { return }
        guard screenCaptureGranted, !updatingCapturePermission, !scope().isArmed, !prewarmInFlight else { return }
        guard let retainThumbnails = dependencies.retainThumbnails,
              let thumbnails = dependencies.thumbnails else { return }
        guard source.loadsThumbnails() else { return }
        prewarmInFlight = true
        defer { prewarmInFlight = false }
        let startEpoch = epoch
        let excluded = source.excludedBundleIDs()
        await source.prepareAllLive(excluded)
        guard canContinuePrewarming(source, epoch: startEpoch, excluded: excluded) else { return }
        // Discovery already caches all Spaces/displays; this is an unscoped read of that
        // snapshot, not a second AX scan. Scope changes must not masquerade as closed IDs.
        await retainThumbnails(source.allLiveWindowIDs(excluded))
        guard canContinuePrewarming(source, epoch: startEpoch, excluded: excluded) else { return }
        // Re-read after the actor hop so a changed screen/scope never warms the old set.
        _ = await thumbnails(source.scopedWindowIDs(), false, nil)
    }

    @MainActor
    private func canContinuePrewarming(_ source: PrewarmSource, epoch: UInt64, excluded: Set<String>) -> Bool {
        !Task.isCancelled && screenCaptureGranted && !updatingCapturePermission && !scope().isArmed
            && self.epoch == epoch && source.loadsThumbnails()
            && source.excludedBundleIDs() == excluded
    }

    // MARK: - Capture

    @MainActor
    private func fetchInitial(for windows: [WindowInfo]) async {
        let scope = self.scope()
        guard scope.isArmed, screenCaptureGranted, !updatingCapturePermission else { return }
        let startEpoch = epoch
        let arm = scope.generation
        if let cancelThumbnailCaptures = dependencies.cancelThumbnailCaptures {
            await cancelThumbnailCaptures()
        }
        let current = self.scope()
        guard current.isArmed, current.generation == arm, epoch == startEpoch else { return }
        await fetch(for: windows, fresh: false)
    }

    @MainActor
    func fetch(for windows: [WindowInfo], fresh: Bool) async {
        let scope = self.scope()
        guard scope.isArmed, screenCaptureGranted, !updatingCapturePermission else { return }
        guard let loadThumbnails = dependencies.thumbnails else { return }
        let generation = scope.generation
        let startEpoch = epoch
        let visibleIDs = Set(scope.windows.map(\.id))
        var ids = windows.map(\.id).filter { visibleIDs.contains($0) && !pendingIDs.contains($0) }
        if let selected = scope.highlightedWindowID, let index = ids.firstIndex(of: selected) {
            ids.remove(at: index)
            ids.insert(selected, at: 0)
        }
        guard !ids.isEmpty else { return }
        pendingIDs.formUnion(ids)
        for id in ids where thumbnailStates[id] == nil { thumbnailStates[id] = .loading }
        let loaded = await loadThumbnails(ids, fresh) { [weak self] id, image in
            guard let self, self.epoch == startEpoch, self.screenCaptureGranted else { return }
            let scope = self.scope()
            guard scope.isArmed, scope.generation == generation,
                  scope.windows.contains(where: { $0.id == id }) else { return }
            self.thumbnails[id] = image
            self.thumbnailStates[id] = .ready
        }
        let current = self.scope()
        guard current.isArmed, current.generation == generation, epoch == startEpoch, screenCaptureGranted else { return }
        pendingIDs.subtract(ids)
        let currentIDs = Set(current.windows.map(\.id))
        for id in ids where currentIDs.contains(id) {
            if let image = loaded[id] { thumbnails[id] = image }
            thumbnailStates[id] = thumbnails[id] == nil ? .unavailable : .ready
        }
    }

    // MARK: - Timers

    /// `Timer.scheduledTimer` only fires in `.default` mode, which pauses while a context
    /// menu or other tracking loop runs; previews must keep refreshing under one.
    private static func scheduleTimer(interval: TimeInterval, repeats: Bool,
                                      block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
