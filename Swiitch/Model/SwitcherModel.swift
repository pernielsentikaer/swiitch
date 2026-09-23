import AppKit
import Combine

/// Drives the switcher UI + window/app focus actions.
final class SwitcherModel: ObservableObject {
    enum Mode: Equatable {
        case apps             // root: app strip
        case windowsForApp    // drilled into selected app's windows
        case flatWindows      // displayMode == .windows: flat list of all windows
        case currentAppWindows // second hotkey: flat list scoped to the frontmost app
    }

    /// Geometry reports are valid only for the invocation, scope, and query that drew them.
    struct ThumbnailViewportContext: Equatable {
        let generation: UInt64
        let epoch: UInt64
        let mode: Mode
        let appPID: pid_t?
        let query: String
    }

    private var thumbnailViewport: (context: ThumbnailViewportContext, ids: Set<CGWindowID>)?

    struct FlatWindowEntry: Identifiable, Hashable {
        let id: CGWindowID
        let window: WindowInfo
        let bundleIdentifier: String?
        let appName: String
        let appIcon: NSImage?
    }

    /// External operations used by the state machine. Keeping these injectable lets the
    /// selection and filtering behavior run under unit tests without focusing real apps,
    /// enumerating the developer's desktop, or requesting Screen Recording permission.
    struct Dependencies {
        var enumerate: (FocusTracker, EnumerateOptions) -> [AppEntry]
        var prepareSnapshot: ((EnumerateOptions) async -> Void)?
        var focusApp: (AppEntry) -> Void
        var focusWindow: (WindowInfo) -> Void
        var closeWindow: (WindowInfo) -> Bool
        var minimizeWindow: (WindowInfo) -> Bool
        var zoomWindow: (WindowInfo) -> Bool
        var hideApp: (pid_t) -> Bool
        var focusPID: (pid_t) -> Void
        var restoreWindowFocus: (pid_t, CGWindowID) -> Bool
        var frontmostPID: () -> pid_t?
        var frontmostBundleID: () -> String?
        var focusedWindowID: (pid_t) -> CGWindowID?
        var thumbnails: ((
            [CGWindowID],
            Bool,
            ThumbnailProgressHandler?
        ) async -> [CGWindowID: NSImage])?
        var cancelThumbnailCaptures: (() async -> Void)?
        var retainThumbnails: ((Set<CGWindowID>) async -> Void)?
        var invalidateThumbnail: ((CGWindowID) async -> Void)?
        var screenCaptureGranted: () -> Bool
        var setThumbnailCaptureAllowed: ((Bool) async -> Void)?
        var scheduleCloseReconciliation: (@escaping () -> Void) -> Void
        var readWindowCapabilities: ((WindowInfo) async -> WindowActionCapabilities)?
        var performWindowAction: ((WindowAction, WindowInfo) -> WindowActionResult)?
        var cancelPendingFocus: () -> Void

        init(
            enumerate: @escaping (FocusTracker, EnumerateOptions) -> [AppEntry],
            focusApp: @escaping (AppEntry) -> Void,
            focusWindow: @escaping (WindowInfo) -> Void,
            closeWindow: @escaping (WindowInfo) -> Bool,
            minimizeWindow: @escaping (WindowInfo) -> Bool = { WindowFocuser.minimize(window: $0) },
            zoomWindow: @escaping (WindowInfo) -> Bool = { WindowFocuser.zoom(window: $0) },
            hideApp: @escaping (pid_t) -> Bool,
            focusPID: @escaping (pid_t) -> Void = { pid in
                MainActor.assumeIsolated { WindowFocuser.focus(pid: pid) }
            },
            restoreWindowFocus: @escaping (pid_t, CGWindowID) -> Bool = { _, _ in false },
            frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            focusedWindowID: @escaping (pid_t) -> CGWindowID? = { AXPrivate.focusedWindowID(forPID: $0) },
            thumbnails: ((
                [CGWindowID],
                Bool,
                ThumbnailProgressHandler?
            ) async -> [CGWindowID: NSImage])? = nil,
            cancelThumbnailCaptures: (() async -> Void)? = nil,
            retainThumbnails: ((Set<CGWindowID>) async -> Void)? = nil,
            invalidateThumbnail: ((CGWindowID) async -> Void)? = nil,
            screenCaptureGranted: @escaping () -> Bool = { true },
            setThumbnailCaptureAllowed: ((Bool) async -> Void)? = nil,
            scheduleCloseReconciliation: @escaping (@escaping () -> Void) -> Void = { action in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
            },
            prepareSnapshot: ((EnumerateOptions) async -> Void)? = nil,
            readWindowCapabilities: ((WindowInfo) async -> WindowActionCapabilities)? = nil,
            performWindowAction: ((WindowAction, WindowInfo) -> WindowActionResult)? = nil,
            cancelPendingFocus: @escaping () -> Void = {}
        ) {
            self.enumerate = enumerate
            self.prepareSnapshot = prepareSnapshot
            self.focusApp = focusApp
            self.focusWindow = focusWindow
            self.closeWindow = closeWindow
            self.minimizeWindow = minimizeWindow
            self.zoomWindow = zoomWindow
            self.hideApp = hideApp
            self.focusPID = focusPID
            self.restoreWindowFocus = restoreWindowFocus
            self.frontmostPID = frontmostPID
            self.frontmostBundleID = frontmostBundleID
            self.focusedWindowID = focusedWindowID
            self.thumbnails = thumbnails
            self.cancelThumbnailCaptures = cancelThumbnailCaptures
            self.retainThumbnails = retainThumbnails
            self.invalidateThumbnail = invalidateThumbnail
            self.screenCaptureGranted = screenCaptureGranted
            self.setThumbnailCaptureAllowed = setThumbnailCaptureAllowed
            self.scheduleCloseReconciliation = scheduleCloseReconciliation
            self.readWindowCapabilities = readWindowCapabilities
            self.performWindowAction = performWindowAction
            self.cancelPendingFocus = cancelPendingFocus
        }

        static let live = Dependencies(
            enumerate: { focusTracker, options in
                MainActor.assumeIsolated {
                    WindowDiscovery.shared.entries(focusTracker: focusTracker, options: options)
                }
            },
            focusApp: { app in MainActor.assumeIsolated { WindowFocuser.focus(app: app) } },
            focusWindow: { window in MainActor.assumeIsolated { WindowFocuser.focus(window: window) } },
            closeWindow: { WindowFocuser.close(window: $0) },
            minimizeWindow: { WindowFocuser.minimize(window: $0) },
            zoomWindow: { WindowFocuser.zoom(window: $0) },
            hideApp: { WindowFocuser.hide(pid: $0) },
            focusPID: { pid in MainActor.assumeIsolated { WindowFocuser.focus(pid: pid) } },
            restoreWindowFocus: { pid, id in
                MainActor.assumeIsolated { WindowFocuser.restoreFocus(pid: pid, windowID: id) }
            },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            focusedWindowID: { AXPrivate.focusedWindowID(forPID: $0) },
            thumbnails: { windowIDs, fresh, onUpdate in
                await WindowThumbnails.shared.images(
                    for: windowIDs,
                    fresh: fresh,
                    // Prewarming fills missing entries only; do not recapture every
                    // background window every four seconds when no picker is visible.
                    maximumAge: onUpdate == nil ? .infinity : 3,
                    onUpdate: onUpdate
                )
            },
            cancelThumbnailCaptures: {
                await WindowThumbnails.shared.cancelPendingCaptures()
            },
            retainThumbnails: { liveIDs in
                await WindowThumbnails.shared.retain(only: liveIDs)
            },
            invalidateThumbnail: { windowID in
                await WindowThumbnails.shared.invalidate(windowID)
            },
            screenCaptureGranted: { CGPreflightScreenCaptureAccess() },
            setThumbnailCaptureAllowed: { allowed in
                await WindowThumbnails.shared.setCaptureAllowed(allowed)
            },
            prepareSnapshot: { await WindowDiscovery.shared.prepare(options: $0) },
            readWindowCapabilities: { await WindowActionCapabilityReader.shared.read($0) },
            performWindowAction: { WindowFocuser.perform($0, window: $1) },
            cancelPendingFocus: { MainActor.assumeIsolated { WindowFocuser.cancelPendingActivation() } }
        )
    }

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var flatWindows: [FlatWindowEntry] = []
    @Published private(set) var mode: Mode = .apps
    @Published private(set) var selectedAppIndex: Int = 0
    @Published private(set) var selectedWindowIndex: Int = 0
    @Published private(set) var selectedFlatIndex: Int = 0
    @Published private(set) var isArmed: Bool = false
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published private(set) var thumbnailStates: [CGWindowID: ThumbnailState] = [:]
    @Published private(set) var screenCaptureGranted: Bool
    @Published private(set) var windowCapabilities: [CGWindowID: WindowActionCapabilities] = [:]
    @Published private(set) var actionFeedback: String?
    /// The usable grid width after the panel subtracts its horizontal padding from the
    /// configured maximum panel width. SwiftUI reads it so `LazyVGrid` knows where to wrap.
    @Published var effectiveMaxWidth: CGFloat = 1200
    @Published var effectiveMaxHeight: CGFloat = 900
    /// True once the user has actually moved the mouse after the panel opened. Hover
    /// callbacks ignore selection changes until this flips, so a stationary cursor that
    /// happens to start inside the panel doesn't snap selection on its own.
    @Published var mouseHasMoved: Bool = false
    /// Filter text typed by the user while the panel is open. Narrows the visible apps
    /// / windows in the current mode by case-insensitive substring match.
    @Published private(set) var filterText: String = ""
    private var appFilterBeforeDrillIn = ""

    var onShow: (() -> Void)?
    var onHide: (() -> Void)?
    var onUpdate: (() -> Void)?

    private let focusTracker: FocusTracker
    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private var showTimer: Timer?
    private var panelShown: Bool = false
    private var prewarmTimer: Timer?
    private var refreshTimer: Timer?
    private var hasArmedOnce = false
    private var peekWorkItem: DispatchWorkItem?
    private var preArmFrontmostPID: pid_t?
    private var preArmFrontmostBundleID: String?
    private var preArmFocusedWindowID: CGWindowID?
    private var hasPeeked = false
    private var pendingCloseWindowIDs: Set<CGWindowID> = []
    private var armGeneration: UInt64 = 0
    private var windowOrder = FocusTracker.WindowOrder()
    private var thumbnailEpoch: UInt64 = 0
    private var pendingThumbnailIDs: Set<CGWindowID> = []
    private var permissionRevision: UInt64 = 0
    private var permissionTransition: Task<Void, Never>?
    private var updatingCapturePermission = false
    private var prewarmInFlight = false
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration: UInt64 = 0
    private var hasPreparedFocus = false
    private var capabilityTasks: [CGWindowID: Task<Void, Never>] = [:]
    private var capabilityCheckedAt: [CGWindowID: TimeInterval] = [:]
    private var capabilityOwners: [CGWindowID: pid_t] = [:]
    private var feedbackTask: Task<Void, Never>?

    init(
        focusTracker: FocusTracker,
        defaults: UserDefaults = .standard,
        dependencies: Dependencies = .live
    ) {
        self.focusTracker = focusTracker
        self.defaults = defaults
        self.dependencies = dependencies
        self.screenCaptureGranted = dependencies.screenCaptureGranted()
    }

    deinit {
        capabilityTasks.values.forEach { $0.cancel() }
        feedbackTask?.cancel()
        if isArmed { focusTracker.isTrackingSuspended = false }
        showTimer?.invalidate()
        prewarmTimer?.invalidate()
        refreshTimer?.invalidate()
        peekWorkItem?.cancel()
    }

    // MARK: - State transitions

    /// Preserve the invocation's original focus while cold background discovery runs.
    /// Warm snapshots return immediately; the input manager queues release/navigation.
    func prepareForArm(completion: @escaping () -> Void) {
        guard !isArmed else { completion(); return }
        dependencies.cancelPendingFocus()
        guard let prepare = dependencies.prepareSnapshot else { completion(); return }
        preparationGeneration &+= 1
        let generation = preparationGeneration
        capturePreArmFocus()
        hasPreparedFocus = true
        let options = currentEnumerateOptions()
        preparationTask = Task { @MainActor [weak self] in
            await prepare(options)
            guard let self, !Task.isCancelled, self.preparationGeneration == generation else { return }
            self.preparationTask = nil
            completion()
        }
    }

    private func captureFocusUnlessPrepared() {
        if !hasPreparedFocus { capturePreArmFocus() }
        hasPreparedFocus = false
    }

    func arm(reverse: Bool) {
        guard !isArmed else { return }
        dependencies.cancelPendingFocus()
        armGeneration &+= 1
        pendingCloseWindowIDs.removeAll()

        captureFocusUnlessPrepared()

        let options = currentEnumerateOptions()
        apps = enumerateOrderedApps(options: options)

        let displayMode = currentDisplayMode()
        switch displayMode {
        case .apps:
            guard !apps.isEmpty else { return }
            selectedAppIndex = initialAppSelectionIndex(reverse: reverse)
            selectedWindowIndex = 0
            mode = .apps

        case .windows:
            flatWindows = orderedFlatWindows(from: apps)
            guard !flatWindows.isEmpty else { return }
            selectedFlatIndex = initialFlatSelectionIndex(reverse: reverse)
            mode = .flatWindows
        }

        focusTracker.isTrackingSuspended = true
        isArmed = true
        scheduleShow()

        if shouldLoadThumbnails(for: displayMode) {
            let allWindows = apps.flatMap { $0.windows }
            requestInitialThumbnails(for: allWindows)
        }
        startRefreshTimer()
        if !hasArmedOnce {
            hasArmedOnce = true
            startPrewarmTimer()
        }

        // Also schedule peek for the initial selection — `.onHover` won't fire if the
        // cursor is already inside a cell's frame when the panel appears (true between
        // back-to-back ⌘+Tab sessions where the cursor hasn't moved).
        schedulePeekIfEnabled()
    }

    /// Arm in "current app's windows" mode — bypasses the apps grid and goes straight to
    /// the window strip for the frontmost app. Triggered by the second configurable hotkey.
    func armForCurrentApp(reverse: Bool) {
        guard !isArmed else { return }
        dependencies.cancelPendingFocus()
        armGeneration &+= 1
        pendingCloseWindowIDs.removeAll()

        captureFocusUnlessPrepared()

        let options = currentEnumerateOptions()
        apps = enumerateOrderedApps(options: options)
        guard !apps.isEmpty else { return }

        // Scope strictly to the frontmost foreign app. If it isn't enumerable (for
        // example, Swiitch itself is frontmost), do not silently show another app.
        let frontmostPID = preArmFrontmostPID
        let frontmostBundle = preArmFrontmostBundleID
        let frontmostApp = frontmostPID.flatMap { pid in
            apps.first { $0.pid == pid }
        } ?? frontmostBundle.flatMap { bundleID in
            apps.first { $0.bundleIdentifier == bundleID }
        }
        guard let app = frontmostApp, !app.windows.isEmpty else { return }

        flatWindows = orderedFlatWindows(from: [app])
        mode = .currentAppWindows
        selectedFlatIndex = initialFlatSelectionIndex(reverse: reverse)

        focusTracker.isTrackingSuspended = true
        isArmed = true
        scheduleShow()

        requestInitialThumbnails(for: app.windows)
        startRefreshTimer()
        if !hasArmedOnce {
            hasArmedOnce = true
            startPrewarmTimer()
        }

        schedulePeekIfEnabled()
    }

    func advance(reverse: Bool) {
        guard isArmed else { return }
        switch mode {
        case .apps:
            let visible = filteredApps
            guard !visible.isEmpty else { return }
            let step = reverse ? -1 : 1
            // Convert current selection from absolute to filtered, step, convert back.
            let currentInFiltered = visible.firstIndex(where: { $0.id == apps[safe: selectedAppIndex]?.id }) ?? 0
            let nextInFiltered = (currentInFiltered + step + visible.count) % visible.count
            if let newIndex = apps.firstIndex(where: { $0.id == visible[nextInFiltered].id }) {
                selectedAppIndex = newIndex
            }
            selectedWindowIndex = 0
        case .windowsForApp:
            let windows = filteredAppWindows
            guard !windows.isEmpty else { return }
            let step = reverse ? -1 : 1
            let current = windows.firstIndex(where: { $0.id == selectedVisibleAppWindow?.id }) ?? 0
            selectAppWindow(id: windows[(current + step + windows.count) % windows.count].id)
        case .flatWindows, .currentAppWindows:
            let visible = filteredFlatWindows
            guard !visible.isEmpty else { return }
            let step = reverse ? -1 : 1
            let currentInFiltered = visible.firstIndex(where: { $0.id == flatWindows[safe: selectedFlatIndex]?.id }) ?? 0
            let nextInFiltered = (currentInFiltered + step + visible.count) % visible.count
            if let newIndex = flatWindows.firstIndex(where: { $0.id == visible[nextInFiltered].id }) {
                selectedFlatIndex = newIndex
            }
        }
        if panelShown { onUpdate?() }
        schedulePeekIfEnabled()
    }

    /// Moves by one visual row. Down enters an app's window grid; Up from the first
    /// per-app row returns to the app grid. Flat-window navigation stays within bounds.
    func advanceRow(reverse: Bool) {
        guard isArmed else { return }

        switch mode {
        case .apps:
            guard !reverse else { return }
            enterWindowMode()
            return

        case .windowsForApp:
            let windows = filteredAppWindows
            guard !windows.isEmpty else {
                if reverse { exitWindowMode() }
                return
            }
            let columns = gridMetrics(count: windows.count, for: .windowsForApp).columns
            let current = windows.firstIndex(where: { $0.id == selectedVisibleAppWindow?.id }) ?? 0
            if reverse, current < columns {
                exitWindowMode()
                return
            }
            let next = max(0, min(windows.count - 1, current + (reverse ? -columns : columns)))
            selectAppWindow(id: windows[next].id)

        case .flatWindows, .currentAppWindows:
            let visible = filteredFlatWindows
            guard !visible.isEmpty else { return }
            let columns = gridMetrics(count: visible.count, for: .flatWindows).columns
            let current = visible.firstIndex(where: {
                $0.id == flatWindows[safe: selectedFlatIndex]?.id
            }) ?? 0
            let next = max(0, min(visible.count - 1, current + (reverse ? -columns : columns)))
            if let absolute = flatWindows.firstIndex(where: { $0.id == visible[next].id }) {
                selectedFlatIndex = absolute
            }
        }

        if panelShown { onUpdate?() }
        schedulePeekIfEnabled()
    }

    struct GridMetrics: Equatable {
        let columns: Int
        let cellWidth: CGFloat
        let thumbnailHeight: CGFloat
    }

    static func appGridColumns(count: Int, maxWidth: CGFloat) -> Int {
        max(1, min(count, Int(maxWidth / (110 + 14))))
    }

    /// Calculates one layout used by both SwiftUI and keyboard row navigation. Automatic
    /// mode preserves the chosen thumbnail size. Fill mode instead finds the largest tiles
    /// that consume the configured width while keeping the complete grid on screen.
    static func gridMetrics(
        count: Int,
        maxWidth: CGFloat,
        availableHeight: CGFloat,
        thumbnailSize: Preferences.ThumbnailSize,
        fitAll: Bool,
        columnSpacing: CGFloat = 12,
        rowSpacing: CGFloat = 14
    ) -> GridMetrics {
        guard count > 0 else {
            return GridMetrics(
                columns: 1,
                cellWidth: thumbnailSize.cellWidth,
                thumbnailHeight: thumbnailSize.thumbHeight
            )
        }

        let width = max(120, maxWidth)
        let preferredWidth = thumbnailSize.cellWidth
        let aspectRatio = thumbnailSize.thumbHeight / preferredWidth

        if !fitAll {
            let columns = max(1, min(count, Int((width + columnSpacing) / (preferredWidth + columnSpacing))))
            return GridMetrics(
                columns: columns,
                cellWidth: preferredWidth,
                thumbnailHeight: thumbnailSize.thumbHeight
            )
        }

        // Fill mode may go smaller than the user's preferred thumbnail size, but retain
        // a usable lower bound. Automatic mode never changes the chosen size.
        let minimumWidth: CGFloat = 72
        let height = max(120, availableHeight)
        let labelHeight: CGFloat = 34

        // Try the fewest columns first. Because each candidate expands to consume the
        // complete configured width, the first layout that fits vertically also produces
        // the largest useful thumbnails. This restores Budapest's visibly distinct Fill
        // behavior instead of collapsing to Automatic whenever full-size tiles fit.
        for columns in 1...count {
            let candidateWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
            guard candidateWidth >= minimumWidth else { continue }
            let cellWidth = candidateWidth
            let thumbnailHeight = cellWidth * aspectRatio
            let rows = Int(ceil(Double(count) / Double(columns)))
            let totalHeight = CGFloat(rows) * (thumbnailHeight + labelHeight)
                + CGFloat(max(0, rows - 1)) * rowSpacing
            if totalHeight <= height {
                return GridMetrics(
                    columns: columns,
                    cellWidth: cellWidth,
                    thumbnailHeight: thumbnailHeight
                )
            }
        }

        // Extremely large sets cannot fit without making tiles unusably small. Use every
        // viable column at the lower bound; the panel's bounded ScrollView handles only
        // this final overflow case instead of letting the panel leave the screen.
        let columns = max(1, min(count, Int((width + columnSpacing) / (minimumWidth + columnSpacing))))
        let candidateWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellWidth = max(minimumWidth, min(preferredWidth, candidateWidth))
        return GridMetrics(
            columns: columns,
            cellWidth: cellWidth,
            thumbnailHeight: cellWidth * aspectRatio
        )
    }

    func gridMetrics(count: Int, for gridMode: Mode) -> GridMetrics {
        let raw = defaults.string(forKey: Preferences.Key.thumbnailSize) ?? Preferences.ThumbnailSize.medium.rawValue
        let size = Preferences.ThumbnailSize(rawValue: raw) ?? .medium
        let reservedHeight: CGFloat = gridMode == .windowsForApp ? 330 : 170
        return Self.gridMetrics(
            count: count,
            maxWidth: effectiveMaxWidth,
            availableHeight: effectiveMaxHeight - reservedHeight,
            thumbnailSize: size,
            fitAll: defaults.bool(forKey: Preferences.Key.fitWindowGridToScreen)
        )
    }

    func enterWindowMode() {
        guard isArmed, mode == .apps else { return }
        // An absolute selection can survive an empty search result. Only a visible
        // app may open its windows; unsuccessful drill-in must preserve the query.
        guard let app = selectedVisibleApp, app.windows.count > 1 else { return }
        appFilterBeforeDrillIn = filterText
        filterText = ""
        mode = .windowsForApp
        selectedWindowIndex = 0
        showTimer?.invalidate()
        presentPanelIfNeeded()
        onUpdate?()
        requestInitialThumbnails(for: app.windows)
    }

    func exitWindowMode() {
        guard isArmed, mode == .windowsForApp else { return }
        mode = .apps
        filterText = appFilterBeforeDrillIn
        appFilterBeforeDrillIn = ""
        clampSelectionToFilter()
        cancelPendingPeek()
        if panelShown { onUpdate?() }
    }

    func selectApp(at index: Int) {
        guard isArmed, mode == .apps, mouseHasMoved, index >= 0, index < apps.count else { return }
        guard index != selectedAppIndex else { return }
        selectedAppIndex = index
        selectedWindowIndex = 0
    }

    /// Accessibility invokes an explicit app identity, independently of pointer movement.
    func chooseWindows(of id: pid_t) {
        guard isArmed, mode == .apps, filteredApps.contains(where: { $0.id == id }),
              let index = apps.firstIndex(where: { $0.id == id }) else { return }
        selectedAppIndex = index
        selectedWindowIndex = 0
        enterWindowMode()
    }

    func selectWindow(at index: Int) {
        guard isArmed, mode == .windowsForApp, mouseHasMoved, let app = currentApp,
              index >= 0, index < app.windows.count,
              filteredAppWindows.contains(where: { $0.id == app.windows[index].id }) else { return }
        guard index != selectedWindowIndex else { return }
        selectedWindowIndex = index
    }

    func selectFlatWindow(at index: Int) {
        guard isArmed, mode == .flatWindows || mode == .currentAppWindows, mouseHasMoved,
              index >= 0, index < flatWindows.count else { return }
        guard index != selectedFlatIndex else { return }
        selectedFlatIndex = index
    }

    /// Explicit clicks are intentional even when the pointer has not moved. Resolve the
    /// displayed identity against the current list, never a stale index or hover selection.
    func commitApp(id: pid_t) {
        guard isArmed, mode == .apps || mode == .windowsForApp,
              filteredApps.contains(where: { $0.id == id }),
              let index = apps.firstIndex(where: { $0.id == id }) else { return }
        selectedAppIndex = index
        selectedWindowIndex = 0
        mode = .apps
        filterText = ""
        commit()
    }

    func commitWindow(id: CGWindowID) {
        guard isArmed else { return }
        switch mode {
        case .apps:
            return
        case .windowsForApp:
            guard filteredAppWindows.contains(where: { $0.id == id }),
                  let index = currentApp?.windows.firstIndex(where: { $0.id == id }) else { return }
            selectedWindowIndex = index
        case .flatWindows, .currentAppWindows:
            guard filteredFlatWindows.contains(where: { $0.id == id }),
                  let index = flatWindows.firstIndex(where: { $0.id == id }) else { return }
            selectedFlatIndex = index
        }
        commit()
    }

    // MARK: - Filtering

    func appendFilter(_ ch: String) {
        guard isArmed else { return }
        showActionFeedback(nil)
        filterText.append(ch)
        clampSelectionToFilter()
        cancelPendingPeek()
        if !panelShown {
            // First keystroke reveals the panel even before the show-delay elapses,
            // otherwise the user wouldn't see what they're filtering.
            showTimer?.invalidate()
            presentPanelIfNeeded()
        }
    }

    func backspaceFilter() {
        guard isArmed, !filterText.isEmpty else { return }
        showActionFeedback(nil)
        filterText.removeLast()
        clampSelectionToFilter()
        cancelPendingPeek()
    }

    func clearFilter() {
        guard !filterText.isEmpty else { return }
        filterText = ""
        clampSelectionToFilter()
        cancelPendingPeek()
    }

    /// Each word may match the app name or one window's title. Never combine words
    /// found only in different windows, since no individual result could satisfy that query.
    var filteredApps: [AppEntry] {
        // The app strip remains stable while the query filters the drilled-in windows.
        let terms = filterText.split(whereSeparator: \.isWhitespace)
        guard mode != .windowsForApp, !terms.isEmpty else { return apps }
        return apps.filter { app in
            matchesFilter(terms, appName: app.name)
                || app.windows.contains(where: { matchesFilter(terms, appName: app.name, title: $0.displayTitle) })
        }
    }

    /// Match all query words across this window's title and owning app name, without reranking.
    var filteredFlatWindows: [FlatWindowEntry] {
        let terms = filterText.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return flatWindows }
        return flatWindows.filter {
            matchesFilter(terms, appName: $0.appName, title: $0.window.displayTitle)
        }
    }

    /// Drill-in search is scoped to this application's windows, never the app strip.
    var filteredAppWindows: [WindowInfo] {
        guard let app = currentApp else { return [] }
        let terms = filterText.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return app.windows }
        return app.windows.filter { matchesFilter(terms, appName: app.name, title: $0.displayTitle) }
    }

    var selectedVisibleAppWindow: WindowInfo? {
        guard let selected = currentApp?.windows[safe: selectedWindowIndex] else { return nil }
        return filteredAppWindows.contains(where: { $0.id == selected.id }) ? selected : nil
    }

    private func selectAppWindow(id: CGWindowID) {
        if let index = currentApp?.windows.firstIndex(where: { $0.id == id }) {
            selectedWindowIndex = index
        }
    }

    private func matchesFilter(_ terms: [Substring], appName: String, title: String? = nil) -> Bool {
        terms.allSatisfy { term in
            appName.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
                || title?.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
        }
    }

    private func clampSelectionToFilter() {
        switch mode {
        case .apps:
            selectedAppIndex = resolvedAbsoluteSelection(
                current: selectedAppIndex,
                all: apps,
                visible: filteredApps,
                id: \AppEntry.id
            )
        case .flatWindows, .currentAppWindows:
            selectedFlatIndex = resolvedAbsoluteSelection(
                current: selectedFlatIndex,
                all: flatWindows,
                visible: filteredFlatWindows,
                id: \FlatWindowEntry.id
            )
        case .windowsForApp:
            selectedWindowIndex = resolvedAbsoluteSelection(
                current: selectedWindowIndex,
                all: currentApp?.windows ?? [],
                visible: filteredAppWindows,
                id: \WindowInfo.id
            )
        }
    }

    /// The selection indices are absolute indices into `apps` / `flatWindows`, while the
    /// UI renders filtered subsets. Preserve the current absolute selection when it remains
    /// visible; otherwise select the first visible item's absolute index.
    private func resolvedAbsoluteSelection<Item, ID: Equatable>(
        current: Int,
        all: [Item],
        visible: [Item],
        id: KeyPath<Item, ID>
    ) -> Int {
        guard let firstVisible = visible.first else { return 0 }
        if all.indices.contains(current) {
            let currentID = all[current][keyPath: id]
            if visible.contains(where: { $0[keyPath: id] == currentID }) {
                return current
            }
        }
        let firstVisibleID = firstVisible[keyPath: id]
        return all.firstIndex(where: { $0[keyPath: id] == firstVisibleID }) ?? 0
    }

    func commit() {
        guard isArmed else { return }
        let mode = self.mode
        let app = mode == .apps ? selectedVisibleApp : currentApp
        let appWindow = selectedVisibleAppWindow
        let flatWindow = selectedVisibleFlatWindow
        let hasVisibleTarget = switch mode {
        case .apps: app != nil
        case .windowsForApp: app != nil && appWindow != nil
        case .flatWindows, .currentAppWindows: flatWindow != nil
        }
        // Releasing an empty search selects nothing. Undo any preview before teardown
        // clears the original focus, just as Escape does; without a preview this is inert.
        guard hasVisibleTarget else { cancel(); return }
        teardown()

        var focusedBundleID: String?
        var focusedWindow: WindowInfo?

        switch mode {
        case .apps:
            guard let app else { return }
            dependencies.focusApp(app)
            focusedBundleID = app.bundleIdentifier
            focusedWindow = app.windows.first
        case .windowsForApp:
            guard let app, let appWindow else { return }
            dependencies.focusWindow(appWindow)
            focusedWindow = appWindow
            focusedBundleID = app.bundleIdentifier
        case .flatWindows, .currentAppWindows:
            guard let flatWindow else { return }
            dependencies.focusWindow(flatWindow.window)
            focusedBundleID = flatWindow.bundleIdentifier
            focusedWindow = flatWindow.window
        }

        if let focusedBundleID {
            focusTracker.bump(focusedBundleID)
        }
        if let focusedWindow {
            focusTracker.bumpWindow(id: focusedWindow.id, pid: focusedWindow.pid)
        }
    }

    func cancel() {
        dependencies.cancelPendingFocus()
        preparationGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        hasPreparedFocus = false
        guard isArmed else { return }
        let originalPID = hasPeeked ? preArmFrontmostPID : nil
        let originalWindowID = preArmFocusedWindowID
        let originalBundleID = preArmFrontmostBundleID
        teardown()

        guard let originalPID else { return }
        // Restoration bypasses picker filtering: the original window can be excluded,
        // on another display, or absent from a refreshed list. Native matching is exact-ID
        // only, so a closed original cannot be mistaken for a similarly named sibling.
        if let originalWindowID,
           dependencies.restoreWindowFocus(originalPID, originalWindowID) {
            focusTracker.bumpWindow(id: originalWindowID, pid: originalPID)
            if let originalBundleID { focusTracker.bump(originalBundleID) }
        } else if dependencies.frontmostPID() != originalPID {
            dependencies.focusPID(originalPID)
        }
    }

    /// Activate the window/app at the current selection without dismissing the picker.
    /// Used by hover-peek so the user can see the candidate window before committing.
    func peekCurrent() {
        guard isArmed else { return }
        switch mode {
        case .apps:
            if let app = selectedVisibleApp {
                hasPeeked = true
                dependencies.focusApp(app)
            }
        case .windowsForApp:
            guard let window = selectedVisibleAppWindow else { return }
            hasPeeked = true
            dependencies.focusWindow(window)
        case .flatWindows, .currentAppWindows:
            guard let flatWindow = selectedVisibleFlatWindow else { return }
            hasPeeked = true
            dependencies.focusWindow(flatWindow.window)
        }
    }

    /// Schedule a peek, if peek-on-hover is enabled. Cancels any pending peek.
    /// Uses `peekDelayMs` from preferences regardless of trigger (keyboard or hover).
    /// Intentionally does NOT gate on `mouseHasMoved` — peek is opt-in via preference,
    /// so the hover/keystroke event itself is sufficient signal of intent.
    func schedulePeekIfEnabled() {
        peekWorkItem?.cancel()
        peekWorkItem = nil
        guard isArmed else { return }
        dependencies.cancelPendingFocus()
        guard defaults.bool(forKey: Preferences.Key.peekOnHover) else { return }

        let configured = defaults.integer(forKey: Preferences.Key.peekDelayMs)
        let resolved = max(50, min(configured == 0 ? 500 : configured, 2500))

        let item = DispatchWorkItem { [weak self] in self?.peekCurrent() }
        peekWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(resolved), execute: item)
    }

    func cancelPendingPeek() {
        // SwiftUI can deliver hover-exit after commit hides the panel. That must not
        // cancel the committed target's newly scheduled activation fallback.
        if isArmed { dependencies.cancelPendingFocus() }
        peekWorkItem?.cancel()
        peekWorkItem = nil
    }

    /// Re-enumerate after a pin/unpin so the order updates while the picker is open.
    /// Selection follows the previously-selected app if still present.
    func refreshAfterPinChange() {
        refreshAfterAppListPreferenceChange()
    }

    /// Re-enumerates after pinning or exclusion changes while keeping the previous
    /// selection when possible. Excluding the final app dismisses the picker safely.
    func refreshAfterAppListPreferenceChange() {
        applyRefreshedAppList()
        guard isArmed, let prepare = dependencies.prepareSnapshot else { return }
        let generation = armGeneration
        var options = currentEnumerateOptions()
        options.forceRefresh = true
        Task { @MainActor [weak self] in
            await prepare(options)
            guard let self, self.isArmed, self.armGeneration == generation else { return }
            self.applyRefreshedAppList()
        }
    }

    private func applyRefreshedAppList() {
        guard isArmed else { return }
        let previouslySelectedID = currentApp?.id
        let previouslySelectedWindowID = selectedVisibleAppWindow?.id
        let previouslySelectedFlatID = flatWindows[safe: selectedFlatIndex]?.id
        let currentAppScopePID = mode == .currentAppWindows
            ? flatWindows.first?.window.pid
            : nil

        let options = currentEnumerateOptions()
        apps = enumerateOrderedApps(options: options)
        let flatWindowApps = currentAppScopePID.map { pid in
            apps.filter { $0.pid == pid }
        } ?? apps
        flatWindows = orderedFlatWindows(from: flatWindowApps)

        guard !apps.isEmpty else {
            teardown()
            return
        }
        if mode == .currentAppWindows && flatWindows.isEmpty {
            teardown()
            return
        }

        if let pid = previouslySelectedID, let newIndex = apps.firstIndex(where: { $0.id == pid }) {
            selectedAppIndex = newIndex
        } else {
            selectedAppIndex = 0
            if mode == .windowsForApp { exitWindowMode() }
        }
        if let id = previouslySelectedWindowID { selectAppWindow(id: id) }
        if let wid = previouslySelectedFlatID, let newIndex = flatWindows.firstIndex(where: { $0.id == wid }) {
            selectedFlatIndex = newIndex
        } else {
            selectedFlatIndex = 0
        }
        clampSelectionToFilter()
        onUpdate?()
    }

    /// Close the currently-selected window (or the frontmost window of the selected app
    /// when in apps mode). The list is reconciled shortly after the native close request,
    /// because AX success only means the button press was delivered; the app may keep the
    /// window open while showing an unsaved-changes sheet.
    func closeSelected() {
        guard isArmed else { return }
        switch mode {
        case .apps:
            guard let app = selectedVisibleApp, let target = app.windows.first else { return }
            _ = requestClose(target)
        case .windowsForApp:
            guard let target = selectedVisibleAppWindow else { return }
            _ = requestClose(target)
        case .flatWindows, .currentAppWindows:
            guard let entry = selectedVisibleFlatWindow else { return }
            _ = requestClose(entry.window)
        }
    }

    /// Close an explicitly hovered window without relying on keyboard selection state.
    /// A successful native close request is reconciled against the actual window list.
    @discardableResult
    func closeWindow(id: CGWindowID) -> Bool {
        guard isArmed, let target = actionWindow(withID: id) else { return false }
        return requestClose(target)
    }

    /// Minimize an explicitly hovered window while leaving the picker and selection intact.
    @discardableResult
    func minimizeWindow(id: CGWindowID) -> Bool {
        guard isArmed, let target = actionWindow(withID: id) else { return false }
        guard performWindowAction(.minimize, target: target) else { return false }
        refreshThumbnailAfterWindowAction(target)
        let generation = armGeneration
        dependencies.scheduleCloseReconciliation { [weak self] in
            guard let self, self.isArmed, self.armGeneration == generation else { return }
            self.refreshAfterAppListPreferenceChange()
        }
        return true
    }

    /// Invoke the target window's native green zoom button while keeping the picker open.
    @discardableResult
    func zoomWindow(id: CGWindowID) -> Bool {
        guard isArmed, let target = actionWindow(withID: id) else { return false }
        guard performWindowAction(.zoom, target: target) else { return false }
        refreshThumbnailAfterWindowAction(target)
        return true
    }

    /// Hide the app under the current selection (every window of it). Cell disappears
    /// from the list. If no entries remain, the picker dismisses.
    func hideSelected() {
        guard isArmed else { return }
        let targetPID: pid_t? = {
            switch mode {
            case .apps:
                return selectedVisibleApp?.pid
            case .windowsForApp:
                return selectedVisibleAppWindow?.pid
            case .flatWindows, .currentAppWindows:
                return selectedVisibleFlatWindow?.window.pid
            }
        }()
        guard let pid = targetPID else { return }
        cancelPendingPeek()
        guard dependencies.hideApp(pid) else {
            showActionFeedback(String(localized: "Couldn’t hide this app. Please try again."))
            return
        }
        showActionFeedback(nil)
        removeApp(pid: pid)
    }

    private func window(withID id: CGWindowID) -> WindowInfo? {
        flatWindows.first(where: { $0.id == id })?.window
            ?? apps.lazy.flatMap(\.windows).first(where: { $0.id == id })
    }

    /// Stale pointer/AX callbacks cannot act on a window outside the current visible scope.
    private func actionWindow(withID id: CGWindowID) -> WindowInfo? {
        switch mode {
        case .flatWindows, .currentAppWindows:
            return filteredFlatWindows.first(where: { $0.id == id })?.window
        case .windowsForApp:
            return filteredAppWindows.first(where: { $0.id == id })
        case .apps:
            return filteredApps.lazy.flatMap(\.windows).first(where: { $0.id == id })
        }
    }

    @discardableResult
    private func requestClose(_ window: WindowInfo) -> Bool {
        guard !pendingCloseWindowIDs.contains(window.id) else { return false }
        guard performWindowAction(.close, target: window) else { return false }
        pendingCloseWindowIDs.insert(window.id)
        let generation = armGeneration
        dependencies.scheduleCloseReconciliation { [weak self] in
            guard let self else { return }
            self.pendingCloseWindowIDs.remove(window.id)
            guard self.isArmed, self.armGeneration == generation else { return }
            self.refreshAfterAppListPreferenceChange()
        }
        return true
    }

    /// Revalidate in the backend at action time, not against a possibly stale UI hint.
    private func performWindowAction(_ action: WindowAction, target: WindowInfo) -> Bool {
        cancelPendingPeek()
        let result: WindowActionResult
        if let perform = dependencies.performWindowAction {
            result = perform(action, target)
        } else {
            let accepted: Bool
            switch action {
            case .close: accepted = dependencies.closeWindow(target)
            case .minimize: accepted = dependencies.minimizeWindow(target)
            case .zoom: accepted = dependencies.zoomWindow(target)
            }
            result = accepted ? .accepted : .failed
        }
        showActionFeedback(result.message(for: action))
        // A mutation invalidates an in-flight capability read as well as cached hints.
        capabilityTasks.removeValue(forKey: target.id)?.cancel()
        capabilityCheckedAt.removeValue(forKey: target.id)
        windowCapabilities.removeValue(forKey: target.id)
        if result == .unsupported || result == .disabled {
            var value = WindowActionCapabilities()
            value[action] = result == .unsupported ? .unsupported : .disabled
            windowCapabilities[target.id] = value
        }
        prepareWindowControls(id: target.id)
        return result == .accepted
    }

    /// Selected/hovered cells request metadata; no new idle timer or all-window AX pass.
    func prepareWindowControls(id: CGWindowID) {
        guard isArmed, let read = dependencies.readWindowCapabilities,
              let target = actionWindow(withID: id) else { return }
        if let owner = capabilityOwners[id], owner != target.pid {
            capabilityTasks.removeValue(forKey: id)?.cancel()
            capabilityCheckedAt.removeValue(forKey: id)
            windowCapabilities.removeValue(forKey: id)
        }
        guard capabilityTasks[id] == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let checked = capabilityCheckedAt[id], now - checked < 2 { return }
        let generation = armGeneration
        capabilityOwners[id] = target.pid
        capabilityTasks[id] = Task { @MainActor [weak self] in
            let capabilities = await read(target)
            guard let self, !Task.isCancelled, self.isArmed, self.armGeneration == generation else { return }
            self.capabilityTasks[id] = nil
            guard self.window(withID: id)?.pid == target.pid else { return }
            // A timed-out read cannot contradict a just-rejected native operation.
            var merged = self.windowCapabilities[id] ?? .init()
            for action in WindowAction.allCases where capabilities[action] != .unknown {
                merged[action] = capabilities[action]
            }
            self.windowCapabilities[id] = merged
            self.capabilityCheckedAt[id] = ProcessInfo.processInfo.systemUptime
        }
    }

    private func showActionFeedback(_ message: String?) {
        feedbackTask?.cancel()
        actionFeedback = message
        guard message != nil else { return }
        feedbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            self?.actionFeedback = nil
        }
    }

    private func refreshThumbnailAfterWindowAction(_ window: WindowInfo) {
        if let invalidateThumbnail = dependencies.invalidateThumbnail {
            Task { await invalidateThumbnail(window.id) }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            await self?.fetchThumbnails(for: [window], fresh: true)
        }
        onUpdate?()
    }

    private func removeWindow(id: CGWindowID) {
        for i in apps.indices {
            apps[i].windows.removeAll { $0.id == id }
        }
        apps.removeAll { $0.windows.isEmpty }
        flatWindows.removeAll { $0.id == id }
        thumbnails.removeValue(forKey: id)
        thumbnailStates.removeValue(forKey: id)
        if let invalidateThumbnail = dependencies.invalidateThumbnail {
            Task { await invalidateThumbnail(id) }
        }

        if (mode == .currentAppWindows && flatWindows.isEmpty)
            || (apps.isEmpty && flatWindows.isEmpty) {
            teardown()
            return
        }
        clampSelectionAfterRemoval()
    }

    private func removeApp(pid: pid_t) {
        let removedDrilledApp = mode == .windowsForApp && currentApp?.pid == pid
        let removedWindowIDs = Set(
            apps.filter { $0.pid == pid }.flatMap { $0.windows.map(\.id) }
        )
        apps.removeAll { $0.pid == pid }
        flatWindows.removeAll { $0.window.pid == pid }
        if removedDrilledApp { exitWindowMode() }
        thumbnails = thumbnails.filter { !removedWindowIDs.contains($0.key) }
        thumbnailStates = thumbnailStates.filter { !removedWindowIDs.contains($0.key) }
        if let invalidateThumbnail = dependencies.invalidateThumbnail {
            for id in removedWindowIDs {
                Task { await invalidateThumbnail(id) }
            }
        }
        if (mode == .currentAppWindows && flatWindows.isEmpty)
            || (apps.isEmpty && flatWindows.isEmpty) {
            teardown()
            return
        }
        clampSelectionAfterRemoval()
    }

    private func clampSelectionAfterRemoval() {
        switch mode {
        case .apps:
            selectedAppIndex = resolvedAbsoluteSelection(
                current: selectedAppIndex,
                all: apps,
                visible: filteredApps,
                id: \AppEntry.id
            )
        case .windowsForApp:
            guard let app = currentApp, !app.windows.isEmpty else {
                exitWindowMode()
                selectedWindowIndex = 0
                return
            }
            clampSelectionToFilter()
        case .flatWindows, .currentAppWindows:
            selectedFlatIndex = resolvedAbsoluteSelection(
                current: selectedFlatIndex,
                all: flatWindows,
                visible: filteredFlatWindows,
                id: \FlatWindowEntry.id
            )
        }
        if panelShown { onUpdate?() }
    }

    private func teardown() {
        dependencies.cancelPendingFocus()
        capabilityTasks.values.forEach { $0.cancel() }
        capabilityTasks.removeAll()
        capabilityCheckedAt.removeAll()
        capabilityOwners.removeAll()
        windowCapabilities.removeAll()
        showActionFeedback(nil)
        focusTracker.isTrackingSuspended = false
        cancelShowTimer()
        stopRefreshTimer()
        peekWorkItem?.cancel()
        peekWorkItem = nil
        isArmed = false
        apps = []
        flatWindows = []
        selectedAppIndex = 0
        selectedWindowIndex = 0
        selectedFlatIndex = 0
        mode = .apps
        thumbnails = [:]
        thumbnailStates = [:]
        thumbnailViewport = nil
        thumbnailEpoch &+= 1
        pendingThumbnailIDs.removeAll()
        mouseHasMoved = false
        filterText = ""
        preArmFrontmostPID = nil
        appFilterBeforeDrillIn = ""
        preArmFrontmostBundleID = nil
        preArmFocusedWindowID = nil
        hasPeeked = false
        if panelShown {
            onHide?()
        }
        panelShown = false
    }

    // MARK: - Show delay

    private func scheduleShow() {
        showTimer?.invalidate()
        panelShown = false

        let delayMs = defaults.integer(forKey: Preferences.Key.switcherShowDelayMs)
        let delay = max(0, min(delayMs, 1000))

        if delay == 0 {
            presentPanelIfNeeded()
            return
        }

        showTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay) / 1000.0, repeats: false) { [weak self] _ in
            self?.presentPanelIfNeeded()
        }
    }

    private func presentPanelIfNeeded() {
        guard isArmed, !panelShown else { return }
        panelShown = true
        onShow?()
    }

    private func cancelShowTimer() {
        showTimer?.invalidate()
        showTimer = nil
    }

    // MARK: - Thumbnails

    func thumbnailState(for id: CGWindowID) -> ThumbnailState {
        if !screenCaptureGranted { return .permissionRequired }
        if thumbnails[id] != nil { return .ready }
        return thumbnailStates[id] ?? .loading
    }

    private var currentThumbnailWindows: [WindowInfo] {
        switch mode {
        case .apps: return []
        case .windowsForApp: return currentApp?.windows ?? []
        case .flatWindows, .currentAppWindows: return flatWindows.map(\.window)
        }
    }

    var thumbnailViewportContext: ThumbnailViewportContext {
        .init(generation: armGeneration, epoch: thumbnailEpoch, mode: mode,
              appPID: mode == .windowsForApp ? currentApp?.pid : nil, query: filterText)
    }

    /// Until layout has reported a viewport, use the search-filtered scope. Once known,
    /// refresh intersecting tiles plus the selected target while it scrolls into view.
    var thumbnailRefreshWindows: [WindowInfo] {
        let candidates: [WindowInfo] = switch mode {
        case .apps: []
        case .windowsForApp: filteredAppWindows
        case .flatWindows, .currentAppWindows: filteredFlatWindows.map(\.window)
        }
        guard let viewport = thumbnailViewport, viewport.context == thumbnailViewportContext else {
            return candidates
        }
        return candidates.filter { viewport.ids.contains($0.id) || $0.id == highlightedWindowID }
    }

    @MainActor
    func updateThumbnailViewport(_ ids: Set<CGWindowID>, context: ThumbnailViewportContext) {
        guard isArmed, context == thumbnailViewportContext else { return }
        let scopedIDs = ids.intersection(currentThumbnailWindows.map(\.id))
        let previous = thumbnailViewport.flatMap { $0.context == context ? $0.ids : nil } ?? []
        thumbnailViewport = (context, scopedIDs)
        let added = scopedIDs.subtracting(previous)
        guard !added.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isArmed, self.thumbnailViewportContext == context else { return }
            let windows = self.thumbnailRefreshWindows.filter { added.contains($0.id) }
            // Reuse cached images immediately; only missing/stale entries need capture.
            await self.fetchThumbnails(for: windows, fresh: false)
        }
    }

    @MainActor
    func refreshVisibleThumbnails() async {
        guard isArmed, panelShown, shouldLoadThumbnailsForCurrentMode else { return }
        await fetchThumbnails(for: thumbnailRefreshWindows, fresh: true)
    }

    /// UI revocation is immediate. Cache transitions are serialized so rapid deny/grant
    /// changes cannot let an older clear wipe a newer capture. No permission prompt here.
    @MainActor
    func updateScreenCapturePermission(_ granted: Bool) {
        guard screenCaptureGranted != granted else { return }
        screenCaptureGranted = granted
        thumbnailEpoch &+= 1
        pendingThumbnailIDs.removeAll()
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
            if granted, self.isArmed {
                await self.fetchInitialThumbnails(for: self.currentThumbnailWindows)
            }
        }
    }

    private func requestInitialThumbnails(for windows: [WindowInfo]) {
        let arm = armGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isArmed, self.armGeneration == arm else { return }
            await self.fetchInitialThumbnails(for: windows)
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.refreshVisibleThumbnails()
            }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func startPrewarmTimer() {
        prewarmTimer?.invalidate()
        prewarmTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isArmed { return }
            Task { [weak self] in
                await self?.prewarmCache()
            }
        }
    }

    /// Retain every live, non-excluded preview; only capture missing previews in the
    /// current display/Spaces/minimized scope. Both lists are cached discovery reads.
    @MainActor
    func prewarmCache() async {
        guard #available(macOS 14.0, *) else { return }
        guard screenCaptureGranted, !updatingCapturePermission, !isArmed, !prewarmInFlight else { return }
        guard let retainThumbnails = dependencies.retainThumbnails,
              let thumbnails = dependencies.thumbnails else { return }
        guard shouldLoadThumbnails(for: currentDisplayMode()) else { return }
        prewarmInFlight = true
        defer { prewarmInFlight = false }
        let epoch = thumbnailEpoch
        let excluded = currentEnumerateOptions().excludedBundleIDs
        let allLiveOptions = EnumerateOptions(excludedBundleIDs: excluded)
        await dependencies.prepareSnapshot?(allLiveOptions)
        guard canContinuePrewarming(epoch: epoch, excluded: excluded) else { return }
        // Discovery already caches all Spaces/displays; this is an unscoped read of that
        // snapshot, not a second AX scan. Scope changes must not masquerade as closed IDs.
        let liveApps = dependencies.enumerate(focusTracker, allLiveOptions)
        let liveIDs = Set(liveApps.flatMap { $0.windows.map(\.id) })
        await retainThumbnails(liveIDs)
        guard canContinuePrewarming(epoch: epoch, excluded: excluded) else { return }
        // Re-read after the actor hop so a changed screen/scope never warms the old set.
        let windows = dependencies.enumerate(focusTracker, currentEnumerateOptions()).flatMap(\.windows)
        _ = await thumbnails(windows.map(\.id), false, nil)
    }

    @MainActor
    private func canContinuePrewarming(epoch: UInt64, excluded: Set<String>) -> Bool {
        !Task.isCancelled && screenCaptureGranted && !updatingCapturePermission && !isArmed
            && thumbnailEpoch == epoch && shouldLoadThumbnails(for: currentDisplayMode())
            && currentEnumerateOptions().excludedBundleIDs == excluded
    }

    @MainActor
    private func fetchInitialThumbnails(for windows: [WindowInfo]) async {
        guard isArmed, screenCaptureGranted, !updatingCapturePermission else { return }
        let epoch = thumbnailEpoch
        let arm = armGeneration
        if let cancelThumbnailCaptures = dependencies.cancelThumbnailCaptures {
            await cancelThumbnailCaptures()
        }
        guard isArmed, armGeneration == arm, thumbnailEpoch == epoch else { return }
        await fetchThumbnails(for: windows, fresh: false)
    }

    @MainActor
    private func fetchThumbnails(for windows: [WindowInfo], fresh: Bool) async {
        guard #available(macOS 14.0, *) else { return }
        guard isArmed, screenCaptureGranted, !updatingCapturePermission else { return }
        guard let loadThumbnails = dependencies.thumbnails else { return }
        let generation = armGeneration
        let epoch = thumbnailEpoch
        let visibleIDs = Set(currentThumbnailWindows.map(\.id))
        var ids = windows.map(\.id).filter { visibleIDs.contains($0) && !pendingThumbnailIDs.contains($0) }
        if let selected = highlightedWindowID, let index = ids.firstIndex(of: selected) {
            ids.remove(at: index)
            ids.insert(selected, at: 0)
        }
        guard !ids.isEmpty else { return }
        pendingThumbnailIDs.formUnion(ids)
        for id in ids where thumbnailStates[id] == nil { thumbnailStates[id] = .loading }
        let loaded = await loadThumbnails(ids, fresh) { [weak self] id, image in
            guard let self, self.isArmed, self.armGeneration == generation,
                  self.thumbnailEpoch == epoch, self.screenCaptureGranted,
                  self.currentThumbnailWindows.contains(where: { $0.id == id }) else { return }
            self.thumbnails[id] = image
            self.thumbnailStates[id] = .ready
        }
        guard isArmed, armGeneration == generation, thumbnailEpoch == epoch, screenCaptureGranted else { return }
        pendingThumbnailIDs.subtract(ids)
        let currentIDs = Set(currentThumbnailWindows.map(\.id))
        for id in ids where currentIDs.contains(id) {
            if let image = loaded[id] { thumbnails[id] = image }
            thumbnailStates[id] = thumbnails[id] == nil ? .unavailable : .ready
        }
    }

    private var highlightedWindowID: CGWindowID? {
        switch mode {
        case .apps: return nil
        case .windowsForApp: return selectedVisibleAppWindow?.id
        case .flatWindows, .currentAppWindows: return flatWindows[safe: selectedFlatIndex]?.id
        }
    }

    // MARK: - Derived

    var currentApp: AppEntry? {
        guard selectedAppIndex >= 0, selectedAppIndex < apps.count else { return nil }
        return apps[selectedAppIndex]
    }

    private var selectedVisibleApp: AppEntry? {
        guard let currentApp else { return nil }
        return filteredApps.contains(where: { $0.id == currentApp.id }) ? currentApp : nil
    }

    private var selectedVisibleFlatWindow: FlatWindowEntry? {
        guard let selected = flatWindows[safe: selectedFlatIndex] else { return nil }
        return filteredFlatWindows.contains(where: { $0.id == selected.id }) ? selected : nil
    }

    // MARK: - Preference reads

    private func currentDisplayMode() -> Preferences.DisplayMode {
        let raw = defaults.string(forKey: Preferences.Key.displayMode) ?? Preferences.DisplayMode.default.rawValue
        return Preferences.DisplayMode(rawValue: raw) ?? .default
    }

    private func shouldLoadThumbnails(for displayMode: Preferences.DisplayMode) -> Bool {
        displayMode == .windows
    }

    private var shouldLoadThumbnailsForCurrentMode: Bool {
        mode != .apps
    }

    private func capturePreArmFocus() {
        focusTracker.refreshWindowObservation()
        preArmFrontmostPID = dependencies.frontmostPID()
        preArmFrontmostBundleID = dependencies.frontmostBundleID()
        preArmFocusedWindowID = preArmFrontmostPID.flatMap(dependencies.focusedWindowID)
        hasPeeked = false
        if let frontmostBundleID = preArmFrontmostBundleID {
            focusTracker.bump(frontmostBundleID)
        }
        if let pid = preArmFrontmostPID, let id = preArmFocusedWindowID {
            focusTracker.bumpWindow(id: id, pid: pid)
        }
        windowOrder = focusTracker.windowOrder
    }

    /// Sort once per invocation (and reuse that snapshot after explicit list changes).
    /// App grouping is retained in Apps mode; the flat list uses global window recency.
    private func enumerateOrderedApps(options: EnumerateOptions) -> [AppEntry] {
        let entries = dependencies.enumerate(focusTracker, options)
        windowOrder.recordMinimizedState(in: entries.flatMap(\.windows))
        let minimizedLast = Preferences.minimizedWindows(in: defaults) == .showLast
        return entries.map { entry in
            var app = entry
            app.windows = windowOrder.sorted(app.windows, window: { $0 }, minimizedLast: minimizedLast)
            return app
        }
    }

    private func orderedFlatWindows(from apps: [AppEntry]) -> [FlatWindowEntry] {
        let entries = apps.flatMap { app in
            app.windows.map { window in
                FlatWindowEntry(
                    id: window.id,
                    window: window,
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.name,
                    appIcon: app.icon
                )
            }
        }
        let pinned = defaults.stringArray(forKey: Preferences.Key.pinnedBundleIDs) ?? []
        return windowOrder.sorted(entries, window: { $0.window },
            minimizedLast: Preferences.minimizedWindows(in: defaults) == .showLast, pinnedRank: {
            pinned.firstIndex(of: $0.bundleIdentifier ?? "") ?? .max
        })
    }

    /// Pins change presentation order, not which app is already active. Start with the
    /// first/last alternative in that order; retain the old fallback only if focus is unknown.
    private func initialAppSelectionIndex(reverse: Bool) -> Int {
        guard apps.count > 1 else { return 0 }
        let currentIndex: Int?
        if let pid = preArmFrontmostPID {
            currentIndex = apps.firstIndex(where: { $0.pid == pid })
        } else if let bundleID = preArmFrontmostBundleID {
            currentIndex = apps.firstIndex(where: { $0.bundleIdentifier == bundleID })
        } else {
            return reverse ? apps.count - 1 : 1
        }
        let alternatives = apps.indices.filter { $0 != currentIndex }
        return reverse ? (alternatives.last ?? 0) : (alternatives.first ?? 0)
    }

    /// The first hotkey press should always point at a different window. The WindowServer's
    /// `.optionAll` order is not a reliable focused-window signal (notably for Dia), so skip
    /// the exact AX-focused ID wherever it appears in the flattened list. Retain the previous
    /// index-based behavior only when Accessibility cannot identify the current window.
    private func initialFlatSelectionIndex(reverse: Bool) -> Int {
        guard flatWindows.count > 1 else { return 0 }
        if let focusedID = preArmFocusedWindowID,
           flatWindows.contains(where: { $0.id == focusedID }) {
            let alternatives = flatWindows.indices.filter { flatWindows[$0].id != focusedID }
            return reverse ? (alternatives.last ?? 0) : (alternatives.first ?? 0)
        }
        return reverse ? flatWindows.count - 1 : 1
    }

    private func currentEnumerateOptions() -> EnumerateOptions {
        EnumerateOptions(
            includeOtherSpaces: defaults.bool(forKey: Preferences.Key.includeOtherSpaces),
            includeMinimizedWindows: Preferences.minimizedWindows(in: defaults) != .hide,
            restrictToActiveScreen: defaults.bool(forKey: Preferences.Key.restrictToActiveScreen),
            excludedBundleIDs: Set(Preferences.excludedBundleIDs(in: defaults))
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
