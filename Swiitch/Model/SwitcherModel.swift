import AppKit
import Combine

/// Drives the switcher UI + window/app focus actions.
final class SwitcherModel: ObservableObject {
    enum Mode: Equatable {
        case apps             // root: app strip
        case windowsForApp    // drilled into selected app's windows
        case flatWindows      // displayMode == .windows: flat list of all windows
    }

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
        var focusApp: (AppEntry) -> Void
        var focusWindow: (WindowInfo) -> Void
        var closeWindow: (WindowInfo) -> Bool
        var hideApp: (pid_t) -> Bool
        var focusPID: (pid_t) -> Void
        var frontmostPID: () -> pid_t?
        var frontmostBundleID: () -> String?
        var thumbnail: ((CGWindowID, Bool) async -> NSImage?)?
        var retainThumbnails: ((Set<CGWindowID>) async -> Void)?
        var invalidateThumbnail: ((CGWindowID) async -> Void)?

        init(
            enumerate: @escaping (FocusTracker, EnumerateOptions) -> [AppEntry],
            focusApp: @escaping (AppEntry) -> Void,
            focusWindow: @escaping (WindowInfo) -> Void,
            closeWindow: @escaping (WindowInfo) -> Bool,
            hideApp: @escaping (pid_t) -> Bool,
            focusPID: @escaping (pid_t) -> Void = { WindowFocuser.focus(pid: $0) },
            frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            thumbnail: ((CGWindowID, Bool) async -> NSImage?)? = nil,
            retainThumbnails: ((Set<CGWindowID>) async -> Void)? = nil,
            invalidateThumbnail: ((CGWindowID) async -> Void)? = nil
        ) {
            self.enumerate = enumerate
            self.focusApp = focusApp
            self.focusWindow = focusWindow
            self.closeWindow = closeWindow
            self.hideApp = hideApp
            self.focusPID = focusPID
            self.frontmostPID = frontmostPID
            self.frontmostBundleID = frontmostBundleID
            self.thumbnail = thumbnail
            self.retainThumbnails = retainThumbnails
            self.invalidateThumbnail = invalidateThumbnail
        }

        static let live = Dependencies(
            enumerate: { focusTracker, options in
                WindowEnumerator.enumerate(focusTracker: focusTracker, options: options)
            },
            focusApp: { WindowFocuser.focus(app: $0) },
            focusWindow: { WindowFocuser.focus(window: $0) },
            closeWindow: { WindowFocuser.close(window: $0) },
            hideApp: { WindowFocuser.hide(pid: $0) },
            focusPID: { WindowFocuser.focus(pid: $0) },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            thumbnail: { windowID, fresh in
                await WindowThumbnails.shared.image(for: windowID, fresh: fresh)
            },
            retainThumbnails: { liveIDs in
                await WindowThumbnails.shared.retain(only: liveIDs)
            },
            invalidateThumbnail: { windowID in
                await WindowThumbnails.shared.invalidate(windowID)
            }
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
    /// Computed by the panel from `maxPanelWidthPercent` × active-screen width. SwiftUI
    /// reads this from the model so `LazyVGrid` knows where to wrap.
    @Published var effectiveMaxWidth: CGFloat = 1200
    @Published var effectiveMaxHeight: CGFloat = 900
    /// True once the user has actually moved the mouse after the panel opened. Hover
    /// callbacks ignore selection changes until this flips, so a stationary cursor that
    /// happens to start inside the panel doesn't snap selection on its own.
    @Published var mouseHasMoved: Bool = false
    /// Filter text typed by the user while the panel is open. Narrows the visible apps
    /// / windows in the current mode by case-insensitive substring match.
    @Published private(set) var filterText: String = ""

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
    private var hasPeeked = false

    init(
        focusTracker: FocusTracker,
        defaults: UserDefaults = .standard,
        dependencies: Dependencies = .live
    ) {
        self.focusTracker = focusTracker
        self.defaults = defaults
        self.dependencies = dependencies
    }

    deinit {
        showTimer?.invalidate()
        prewarmTimer?.invalidate()
        refreshTimer?.invalidate()
        peekWorkItem?.cancel()
    }

    // MARK: - State transitions

    func arm(reverse: Bool) {
        guard !isArmed else { return }

        capturePreArmFocus()

        let options = currentEnumerateOptions()
        apps = dependencies.enumerate(focusTracker, options)

        let displayMode = currentDisplayMode()
        switch displayMode {
        case .apps:
            guard !apps.isEmpty else { return }
            if apps.count > 1 {
                selectedAppIndex = reverse ? apps.count - 1 : 1
            } else {
                selectedAppIndex = 0
            }
            selectedWindowIndex = 0
            mode = .apps

        case .windows:
            flatWindows = apps.flatMap { app in
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
            guard !flatWindows.isEmpty else { return }
            if flatWindows.count > 1 {
                selectedFlatIndex = reverse ? flatWindows.count - 1 : 1
            } else {
                selectedFlatIndex = 0
            }
            mode = .flatWindows
        }

        isArmed = true
        scheduleShow()

        if shouldLoadThumbnails(for: displayMode) {
            let allWindows = apps.flatMap { $0.windows }
            Task { [weak self] in
                await self?.fetchThumbnails(for: allWindows, fresh: false)
            }
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

        capturePreArmFocus()

        let options = currentEnumerateOptions()
        apps = dependencies.enumerate(focusTracker, options)
        guard !apps.isEmpty else { return }

        // Find the entry for the frontmost foreign app (the one whose windows we want).
        let frontmostBundle = dependencies.frontmostBundleID()
        if let idx = apps.firstIndex(where: { $0.bundleIdentifier == frontmostBundle }) {
            selectedAppIndex = idx
        } else {
            selectedAppIndex = 0
        }

        let app = apps[selectedAppIndex]
        guard app.windows.count >= 1 else { return }

        // Jump straight into window-mode.
        mode = .windowsForApp
        if app.windows.count > 1 {
            selectedWindowIndex = reverse ? app.windows.count - 1 : 1
        } else {
            selectedWindowIndex = 0
        }

        isArmed = true
        scheduleShow()

        // Snapshot fan-out.
        let allWindows = apps.flatMap { $0.windows }
        Task { [weak self] in
            await self?.fetchThumbnails(for: allWindows, fresh: false)
        }
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
            let windows = currentApp?.windows ?? []
            guard !windows.isEmpty else { return }
            let step = reverse ? -1 : 1
            selectedWindowIndex = (selectedWindowIndex + step + windows.count) % windows.count
        case .flatWindows:
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
            let windows = currentApp?.windows ?? []
            guard !windows.isEmpty else { return }
            let columns = gridMetrics(count: windows.count, for: .windowsForApp).columns
            if reverse, selectedWindowIndex < columns {
                exitWindowMode()
                return
            }
            let next = selectedWindowIndex + (reverse ? -columns : columns)
            selectedWindowIndex = max(0, min(windows.count - 1, next))

        case .flatWindows:
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

    /// Calculates one layout used by both SwiftUI and keyboard row navigation. Fit mode
    /// first uses the selected wrap width, then adds columns and shrinks tiles only when
    /// necessary to keep the complete grid on screen. Tiles never grow beyond the chosen
    /// thumbnail preset.
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

        let minimumWidth: CGFloat = 120
        let height = max(120, availableHeight)
        let labelHeight: CGFloat = 34

        // Begin with the number of full-size tiles that naturally use the selected wrap
        // width. Starting at one column made tall/portrait displays choose the narrowest
        // grid that only just fit vertically (for example, 18 windows in a two-column
        // tower), leaving most of the configured width unused.
        let preferredColumns = max(
            1,
            min(count, Int((width + columnSpacing) / (preferredWidth + columnSpacing)))
        )

        for columns in preferredColumns...count {
            let candidateWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
            guard candidateWidth >= minimumWidth else { continue }
            let cellWidth = min(preferredWidth, candidateWidth)
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

        // Very large window sets may not fit above the minimum comfortable tile width.
        // Use the densest width-safe grid; the panel can still grow vertically as before.
        let columns = max(1, min(count, Int((width + columnSpacing) / (minimumWidth + columnSpacing))))
        let candidateWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellWidth = max(96, min(preferredWidth, candidateWidth))
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
        guard defaults.bool(forKey: Preferences.Key.showWindowPreviews) else { return }
        guard let app = currentApp, app.windows.count > 1 else { return }
        filterText = ""
        mode = .windowsForApp
        selectedWindowIndex = 0
        showTimer?.invalidate()
        presentPanelIfNeeded()
        onUpdate?()
    }

    func exitWindowMode() {
        guard isArmed, mode == .windowsForApp else { return }
        mode = .apps
        if panelShown { onUpdate?() }
    }

    func selectApp(at index: Int) {
        guard isArmed, mode == .apps, mouseHasMoved, index >= 0, index < apps.count else { return }
        guard index != selectedAppIndex else { return }
        selectedAppIndex = index
        selectedWindowIndex = 0
    }

    func selectWindow(at index: Int) {
        guard isArmed, mode == .windowsForApp, mouseHasMoved, let app = currentApp,
              index >= 0, index < app.windows.count else { return }
        guard index != selectedWindowIndex else { return }
        selectedWindowIndex = index
    }

    func selectFlatWindow(at index: Int) {
        guard isArmed, mode == .flatWindows, mouseHasMoved,
              index >= 0, index < flatWindows.count else { return }
        guard index != selectedFlatIndex else { return }
        selectedFlatIndex = index
    }

    // MARK: - Filtering

    func appendFilter(_ ch: String) {
        guard isArmed, mode != .windowsForApp else { return } // window-mode drill-in stays as-is
        filterText.append(ch)
        clampSelectionToFilter()
        if !panelShown {
            // First keystroke reveals the panel even before the show-delay elapses,
            // otherwise the user wouldn't see what they're filtering.
            showTimer?.invalidate()
            presentPanelIfNeeded()
        }
    }

    func backspaceFilter() {
        guard isArmed, !filterText.isEmpty else { return }
        filterText.removeLast()
        clampSelectionToFilter()
    }

    func clearFilter() {
        guard !filterText.isEmpty else { return }
        filterText = ""
        clampSelectionToFilter()
    }

    /// Apps after applying the filter — name substring, case-insensitive.
    var filteredApps: [AppEntry] {
        guard !filterText.isEmpty else { return apps }
        return apps.filter { app in
            matchesFilter(app.name)
                || app.windows.contains(where: { matchesFilter($0.displayTitle) })
        }
    }

    /// Flat windows after applying the filter — title OR owning app name.
    var filteredFlatWindows: [FlatWindowEntry] {
        guard !filterText.isEmpty else { return flatWindows }
        return flatWindows.filter {
            matchesFilter($0.window.displayTitle) || matchesFilter($0.appName)
        }
    }

    private func matchesFilter(_ candidate: String) -> Bool {
        candidate.range(
            of: filterText,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
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
        case .flatWindows:
            selectedFlatIndex = resolvedAbsoluteSelection(
                current: selectedFlatIndex,
                all: flatWindows,
                visible: filteredFlatWindows,
                id: \FlatWindowEntry.id
            )
        case .windowsForApp:
            break
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
        let windowIndex = selectedWindowIndex
        let flatWindow = selectedVisibleFlatWindow
        teardown()

        var focusedBundleID: String?

        switch mode {
        case .apps:
            guard let app else { return }
            dependencies.focusApp(app)
            focusedBundleID = app.bundleIdentifier
        case .windowsForApp:
            guard let app else { return }
            let windows = app.windows
            if windowIndex < windows.count {
                dependencies.focusWindow(windows[windowIndex])
            } else {
                dependencies.focusApp(app)
            }
            focusedBundleID = app.bundleIdentifier
        case .flatWindows:
            guard let flatWindow else { return }
            dependencies.focusWindow(flatWindow.window)
            focusedBundleID = flatWindow.bundleIdentifier
        }

        if let focusedBundleID {
            focusTracker.bump(focusedBundleID)
        }
    }

    func cancel() {
        guard isArmed else { return }
        let originalPID = hasPeeked ? preArmFrontmostPID : nil
        teardown()

        guard let originalPID,
              dependencies.frontmostPID() != originalPID
        else { return }
        dependencies.focusPID(originalPID)
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
            guard let app = currentApp,
                  selectedWindowIndex < app.windows.count else { return }
            hasPeeked = true
            dependencies.focusWindow(app.windows[selectedWindowIndex])
        case .flatWindows:
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
        guard defaults.bool(forKey: Preferences.Key.peekOnHover) else { return }

        let configured = defaults.integer(forKey: Preferences.Key.peekDelayMs)
        let resolved = max(50, min(configured == 0 ? 500 : configured, 2500))

        let item = DispatchWorkItem { [weak self] in self?.peekCurrent() }
        peekWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(resolved), execute: item)
    }

    func cancelPendingPeek() {
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
        guard isArmed else { return }
        let previouslySelectedID = currentApp?.id
        let previouslySelectedFlatID = flatWindows[safe: selectedFlatIndex]?.id

        let options = currentEnumerateOptions()
        apps = dependencies.enumerate(focusTracker, options)
        flatWindows = apps.flatMap { app in
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

        guard !apps.isEmpty else {
            teardown()
            return
        }

        if let pid = previouslySelectedID, let newIndex = apps.firstIndex(where: { $0.id == pid }) {
            selectedAppIndex = newIndex
        } else {
            selectedAppIndex = 0
        }
        if let wid = previouslySelectedFlatID, let newIndex = flatWindows.firstIndex(where: { $0.id == wid }) {
            selectedFlatIndex = newIndex
        } else {
            selectedFlatIndex = 0
        }
        clampSelectionToFilter()
        onUpdate?()
    }

    /// Close the currently-selected window (or the frontmost window of the selected app
    /// when in apps mode). Optimistically removes the row from the visible list so the
    /// UI updates immediately — the AX call is best-effort and may be ignored by the
    /// target app (e.g. unsaved-changes dialog).
    func closeSelected() {
        guard isArmed else { return }
        switch mode {
        case .apps:
            guard let app = selectedVisibleApp, let target = app.windows.first else { return }
            guard dependencies.closeWindow(target) else { return }
            removeWindow(id: target.id)
        case .windowsForApp:
            guard let app = currentApp,
                  selectedWindowIndex >= 0, selectedWindowIndex < app.windows.count else { return }
            let target = app.windows[selectedWindowIndex]
            guard dependencies.closeWindow(target) else { return }
            removeWindow(id: target.id)
        case .flatWindows:
            guard let entry = selectedVisibleFlatWindow else { return }
            guard dependencies.closeWindow(entry.window) else { return }
            removeWindow(id: entry.id)
        }
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
                return currentApp?.pid
            case .flatWindows:
                return selectedVisibleFlatWindow?.window.pid
            }
        }()
        guard let pid = targetPID else { return }
        guard dependencies.hideApp(pid) else { return }
        removeApp(pid: pid)
    }

    private func removeWindow(id: CGWindowID) {
        for i in apps.indices {
            apps[i].windows.removeAll { $0.id == id }
        }
        apps.removeAll { $0.windows.isEmpty }
        flatWindows.removeAll { $0.id == id }
        thumbnails.removeValue(forKey: id)
        if let invalidateThumbnail = dependencies.invalidateThumbnail {
            Task { await invalidateThumbnail(id) }
        }

        if apps.isEmpty && flatWindows.isEmpty {
            teardown()
            return
        }
        clampSelectionAfterRemoval()
    }

    private func removeApp(pid: pid_t) {
        let removedWindowIDs = Set(
            apps.filter { $0.pid == pid }.flatMap { $0.windows.map(\.id) }
        )
        apps.removeAll { $0.pid == pid }
        flatWindows.removeAll { $0.window.pid == pid }
        thumbnails = thumbnails.filter { !removedWindowIDs.contains($0.key) }
        if let invalidateThumbnail = dependencies.invalidateThumbnail {
            for id in removedWindowIDs {
                Task { await invalidateThumbnail(id) }
            }
        }
        if apps.isEmpty && flatWindows.isEmpty {
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
            guard let app = currentApp else { mode = .apps; selectedWindowIndex = 0; return }
            if app.windows.isEmpty { mode = .apps; selectedWindowIndex = 0; return }
            if selectedWindowIndex >= app.windows.count { selectedWindowIndex = max(0, app.windows.count - 1) }
        case .flatWindows:
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
        mouseHasMoved = false
        filterText = ""
        preArmFrontmostPID = nil
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

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isArmed, self.panelShown else { return }
            guard self.shouldLoadThumbnailsForCurrentMode else { return }
            let ws = self.apps.flatMap { $0.windows }
            Task { [weak self] in
                await self?.fetchThumbnails(for: ws, fresh: true)
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

    private func prewarmCache() async {
        guard #available(macOS 14.0, *) else { return }
        guard let retainThumbnails = dependencies.retainThumbnails,
              let thumbnail = dependencies.thumbnail else { return }
        let shouldPrewarm = await MainActor.run {
            self.shouldLoadThumbnails(for: self.currentDisplayMode())
        }
        guard shouldPrewarm else { return }
        let opts = await MainActor.run { self.currentEnumerateOptions() }
        let apps = await MainActor.run {
            self.dependencies.enumerate(self.focusTracker, opts)
        }
        let windows = apps.flatMap { $0.windows }
        let liveIDs = Set(windows.map { $0.id })
        await retainThumbnails(liveIDs)
        await withTaskGroup(of: Void.self) { group in
            for window in windows {
                group.addTask {
                    _ = await thumbnail(window.id, false)
                }
            }
        }
    }

    private func fetchThumbnails(for windows: [WindowInfo], fresh: Bool) async {
        guard #available(macOS 14.0, *) else { return }
        guard let thumbnail = dependencies.thumbnail else { return }
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in windows {
                group.addTask {
                    let img = await thumbnail(window.id, fresh)
                    return (window.id, img)
                }
            }
            for await (id, img) in group {
                guard let img else { continue }
                await MainActor.run { [weak self] in
                    self?.thumbnails[id] = img
                }
            }
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
        let raw = defaults.string(forKey: Preferences.Key.displayMode) ?? Preferences.DisplayMode.apps.rawValue
        return Preferences.DisplayMode(rawValue: raw) ?? .apps
    }

    private func shouldLoadThumbnails(for displayMode: Preferences.DisplayMode) -> Bool {
        displayMode == .windows || defaults.bool(forKey: Preferences.Key.showWindowPreviews)
    }

    private var shouldLoadThumbnailsForCurrentMode: Bool {
        mode != .apps || defaults.bool(forKey: Preferences.Key.showWindowPreviews)
    }

    private func capturePreArmFocus() {
        preArmFrontmostPID = dependencies.frontmostPID()
        hasPeeked = false
        if let frontmostBundleID = dependencies.frontmostBundleID() {
            focusTracker.bump(frontmostBundleID)
        }
    }

    private func currentEnumerateOptions() -> EnumerateOptions {
        EnumerateOptions(
            includeOtherSpaces: defaults.bool(forKey: Preferences.Key.includeOtherSpaces),
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
