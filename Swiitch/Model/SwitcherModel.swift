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
        let appName: String
        let appIcon: NSImage?
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
    private var showTimer: Timer?
    private var panelShown: Bool = false
    private var prewarmTimer: Timer?
    private var refreshTimer: Timer?
    private var hasArmedOnce = false
    private var peekWorkItem: DispatchWorkItem?

    init(focusTracker: FocusTracker) {
        self.focusTracker = focusTracker
    }

    // MARK: - State transitions

    func arm(reverse: Bool) {
        guard !isArmed else { return }

        let options = currentEnumerateOptions()
        apps = WindowEnumerator.enumerate(focusTracker: focusTracker, options: options)

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
                    FlatWindowEntry(id: window.id, window: window, appName: app.name, appIcon: app.icon)
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

        // Kick off thumbnail fetch — useful for both display modes.
        let allWindows = apps.flatMap { $0.windows }
        Task { [weak self] in
            await self?.fetchThumbnails(for: allWindows, fresh: false)
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

        let options = currentEnumerateOptions()
        apps = WindowEnumerator.enumerate(focusTracker: focusTracker, options: options)
        guard !apps.isEmpty else { return }

        // Find the entry for the frontmost foreign app (the one whose windows we want).
        let frontmostBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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

    func enterWindowMode() {
        guard isArmed, mode == .apps else { return }
        guard let app = currentApp, app.windows.count > 1 else { return }
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
        return apps.filter { $0.name.range(of: filterText, options: .caseInsensitive) != nil }
    }

    /// Flat windows after applying the filter — title OR owning app name.
    var filteredFlatWindows: [FlatWindowEntry] {
        guard !filterText.isEmpty else { return flatWindows }
        return flatWindows.filter {
            $0.window.title.range(of: filterText, options: .caseInsensitive) != nil
                || $0.appName.range(of: filterText, options: .caseInsensitive) != nil
        }
    }

    private func clampSelectionToFilter() {
        switch mode {
        case .apps:
            selectedAppIndex = filteredApps.isEmpty ? 0 : min(selectedAppIndex, filteredApps.count - 1)
            if selectedAppIndex < 0 { selectedAppIndex = 0 }
        case .flatWindows:
            selectedFlatIndex = filteredFlatWindows.isEmpty ? 0 : min(selectedFlatIndex, filteredFlatWindows.count - 1)
            if selectedFlatIndex < 0 { selectedFlatIndex = 0 }
        case .windowsForApp:
            break
        }
    }

    func commit() {
        guard isArmed else { return }
        let mode = self.mode
        let app = currentApp
        let windowIndex = selectedWindowIndex
        let flatIndex = selectedFlatIndex
        let flat = flatWindows
        teardown()

        switch mode {
        case .apps:
            guard let app else { return }
            WindowFocuser.focus(app: app)
        case .windowsForApp:
            guard let app else { return }
            let windows = app.windows
            guard windowIndex < windows.count else {
                WindowFocuser.focus(app: app)
                return
            }
            WindowFocuser.focus(window: windows[windowIndex])
        case .flatWindows:
            guard flatIndex < flat.count else { return }
            WindowFocuser.focus(window: flat[flatIndex].window)
        }
    }

    func cancel() {
        guard isArmed else { return }
        teardown()
    }

    /// Activate the window/app at the current selection without dismissing the picker.
    /// Used by hover-peek so the user can see the candidate window before committing.
    func peekCurrent() {
        guard isArmed else { return }
        switch mode {
        case .apps:
            if let app = currentApp { WindowFocuser.focus(app: app) }
        case .windowsForApp:
            guard let app = currentApp,
                  selectedWindowIndex < app.windows.count else { return }
            WindowFocuser.focus(window: app.windows[selectedWindowIndex])
        case .flatWindows:
            guard selectedFlatIndex < flatWindows.count else { return }
            WindowFocuser.focus(window: flatWindows[selectedFlatIndex].window)
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
        guard UserDefaults.standard.bool(forKey: Preferences.Key.peekOnHover) else { return }

        let configured = UserDefaults.standard.integer(forKey: Preferences.Key.peekDelayMs)
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
        guard isArmed else { return }
        let previouslySelectedID = currentApp?.id
        let previouslySelectedFlatID = flatWindows[safe: selectedFlatIndex]?.id

        let options = currentEnumerateOptions()
        apps = WindowEnumerator.enumerate(focusTracker: focusTracker, options: options)
        flatWindows = apps.flatMap { app in
            app.windows.map { window in
                FlatWindowEntry(id: window.id, window: window, appName: app.name, appIcon: app.icon)
            }
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
            guard let app = currentApp, let target = app.windows.first else { return }
            WindowFocuser.close(window: target)
            removeWindow(id: target.id)
        case .windowsForApp:
            guard let app = currentApp,
                  selectedWindowIndex >= 0, selectedWindowIndex < app.windows.count else { return }
            let target = app.windows[selectedWindowIndex]
            WindowFocuser.close(window: target)
            removeWindow(id: target.id)
        case .flatWindows:
            guard selectedFlatIndex >= 0, selectedFlatIndex < flatWindows.count else { return }
            let entry = flatWindows[selectedFlatIndex]
            WindowFocuser.close(window: entry.window)
            removeWindow(id: entry.id)
        }
    }

    /// Hide the app under the current selection (every window of it). Cell disappears
    /// from the list. If no entries remain, the picker dismisses.
    func hideSelected() {
        guard isArmed else { return }
        let targetPID: pid_t? = {
            switch mode {
            case .apps, .windowsForApp:
                return currentApp?.pid
            case .flatWindows:
                guard selectedFlatIndex < flatWindows.count else { return nil }
                return flatWindows[selectedFlatIndex].window.pid
            }
        }()
        guard let pid = targetPID else { return }
        WindowFocuser.hide(pid: pid)
        removeApp(pid: pid)
    }

    private func removeWindow(id: CGWindowID) {
        for i in apps.indices {
            apps[i].windows.removeAll { $0.id == id }
        }
        apps.removeAll { $0.windows.isEmpty }
        flatWindows.removeAll { $0.id == id }
        thumbnails.removeValue(forKey: id)

        if apps.isEmpty && flatWindows.isEmpty {
            teardown()
            return
        }
        clampSelectionAfterRemoval()
    }

    private func removeApp(pid: pid_t) {
        apps.removeAll { $0.pid == pid }
        flatWindows.removeAll { $0.window.pid == pid }
        if apps.isEmpty && flatWindows.isEmpty {
            teardown()
            return
        }
        clampSelectionAfterRemoval()
    }

    private func clampSelectionAfterRemoval() {
        switch mode {
        case .apps:
            let visible = filteredApps
            if selectedAppIndex >= apps.count { selectedAppIndex = max(0, apps.count - 1) }
            if !visible.isEmpty,
               !visible.contains(where: { $0.id == apps[safe: selectedAppIndex]?.id }) {
                if let firstAbs = apps.firstIndex(where: { $0.id == visible[0].id }) {
                    selectedAppIndex = firstAbs
                }
            }
        case .windowsForApp:
            guard let app = currentApp else { mode = .apps; selectedWindowIndex = 0; return }
            if app.windows.isEmpty { mode = .apps; selectedWindowIndex = 0; return }
            if selectedWindowIndex >= app.windows.count { selectedWindowIndex = max(0, app.windows.count - 1) }
        case .flatWindows:
            if selectedFlatIndex >= flatWindows.count {
                selectedFlatIndex = max(0, flatWindows.count - 1)
            }
        }
        if panelShown { onUpdate?() }
    }

    private func teardown() {
        cancelShowTimer()
        stopRefreshTimer()
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
        if panelShown {
            onHide?()
        }
        panelShown = false
    }

    // MARK: - Show delay

    private func scheduleShow() {
        showTimer?.invalidate()
        panelShown = false

        let delayMs = UserDefaults.standard.integer(forKey: Preferences.Key.switcherShowDelayMs)
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
        let opts = await MainActor.run { self.currentEnumerateOptions() }
        let apps = await MainActor.run {
            WindowEnumerator.enumerate(focusTracker: self.focusTracker, options: opts)
        }
        let windows = apps.flatMap { $0.windows }
        let liveIDs = Set(windows.map { $0.id })
        await WindowThumbnails.shared.retain(only: liveIDs)
        await withTaskGroup(of: Void.self) { group in
            for window in windows {
                group.addTask {
                    _ = await WindowThumbnails.shared.image(for: window.id, fresh: false)
                }
            }
        }
    }

    private func fetchThumbnails(for windows: [WindowInfo], fresh: Bool) async {
        guard #available(macOS 14.0, *) else { return }
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in windows {
                group.addTask {
                    let img = await WindowThumbnails.shared.image(for: window.id, fresh: fresh)
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

    // MARK: - Preference reads

    private func currentDisplayMode() -> Preferences.DisplayMode {
        let raw = UserDefaults.standard.string(forKey: Preferences.Key.displayMode) ?? Preferences.DisplayMode.apps.rawValue
        return Preferences.DisplayMode(rawValue: raw) ?? .apps
    }

    private func currentEnumerateOptions() -> EnumerateOptions {
        EnumerateOptions(
            includeOtherSpaces: UserDefaults.standard.bool(forKey: Preferences.Key.includeOtherSpaces),
            restrictToActiveScreen: UserDefaults.standard.bool(forKey: Preferences.Key.restrictToActiveScreen)
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
