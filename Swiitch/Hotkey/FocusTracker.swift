import AppKit
import ApplicationServices

/// Tracks app and individual-window activation on the main run loop, including changes
/// made outside Swiitch. WindowServer list order is only a fallback for unseen windows.
@MainActor
final class FocusTracker {
    struct WindowKey: Hashable {
        let pid: pid_t
        let id: CGWindowID
    }

    /// A value snapshot keeps an open picker's ordering independent of later focus events.
    struct WindowOrder {
        var ranks: [WindowKey: Int] = [:]
        private var minimizedAtFirstAppearance: [WindowKey: Bool] = [:]
        private var onScreenAtFirstAppearance: [WindowKey: Bool] = [:]

        init(ranks: [WindowKey: Int] = [:]) {
            self.ranks = ranks
        }

        /// Freeze each window's group for this invocation. Later state changes can update
        /// its label without moving the tile; newly discovered windows still get a group.
        /// The on-screen state is frozen the same way: a peek that switches Space must not
        /// reshuffle the grid underneath the pointer.
        mutating func recordMinimizedState(in windows: [WindowInfo]) {
            for window in windows {
                let key = WindowKey(pid: window.pid, id: window.id)
                if minimizedAtFirstAppearance[key] == nil {
                    minimizedAtFirstAppearance[key] = window.isMinimized == true
                }
                if onScreenAtFirstAppearance[key] == nil {
                    onScreenAtFirstAppearance[key] = window.isOnScreen
                }
            }
        }

        func sorted<Item>(
            _ items: [Item],
            window: (Item) -> WindowInfo,
            minimizedLast: Bool = false,
            pinnedRank: (Item) -> Int = { _ in .max }
        ) -> [Item] {
            items.enumerated().sorted { lhs, rhs in
                let lWindow = window(lhs.element)
                let rWindow = window(rhs.element)
                if minimizedLast {
                    let lMinimized = minimizedAtFirstAppearance[WindowKey(pid: lWindow.pid, id: lWindow.id)] ?? false
                    let rMinimized = minimizedAtFirstAppearance[WindowKey(pid: rWindow.pid, id: rWindow.id)] ?? false
                    if lMinimized != rMinimized { return !lMinimized }
                }
                let lPin = pinnedRank(lhs.element)
                let rPin = pinnedRank(rhs.element)
                if lPin != rPin { return lPin < rPin }
                let lKey = WindowKey(pid: lWindow.pid, id: lWindow.id)
                let rKey = WindowKey(pid: rWindow.pid, id: rWindow.id)
                let lRank = ranks[lKey] ?? .max
                let rRank = ranks[rKey] ?? .max
                if lRank != rRank { return lRank < rRank }
                // Windows the user has never focused keep WindowServer order, except that
                // those on the current Space come before those the user cannot see.
                let lOnScreen = onScreenAtFirstAppearance[lKey] ?? lWindow.isOnScreen
                let rOnScreen = onScreenAtFirstAppearance[rKey] ?? rWindow.isOnScreen
                if lOnScreen != rOnScreen { return lOnScreen }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    private(set) var mruByBundle: [String] = []
    private(set) var mruWindows: [WindowKey] = []
    /// Hover-peek is not a committed app or window visit. The model resumes both
    /// histories before recording an intentional commit or restoring original focus.
    var isTrackingSuspended = false
    private static let historyLimit = 512
    private var observer: MainActorResource<NSObjectProtocol>?
    private var terminationObserver: MainActorResource<NSObjectProtocol>?
    private var windowObserver: MainActorResource<(observer: AXObserver, context: CallbackContext)>?
    @MainActor private final class CallbackContext {
        weak var tracker: FocusTracker?
        init(_ tracker: FocusTracker) { self.tracker = tracker }
    }
    private var observedPID: pid_t?
    private var isRunning = false

    var windowOrder: WindowOrder {
        WindowOrder(ranks: Dictionary(uniqueKeysWithValues: mruWindows.enumerated().map { ($0.element, $0.offset) }))
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Seed with current ordering.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var seen = Set<String>()
        var seed: [String] = []
        if let frontmost { seed.append(frontmost); seen.insert(frontmost) }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, !seen.contains(id) else { continue }
            seed.append(id)
            seen.insert(id)
        }
        mruByBundle = seed

        observer = MainActorResource(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                if let bundleID { self.bump(bundleID) }
                self.refreshWindowObservation()
                self.recordFrontmostWindow()
            }
        }) { NSWorkspace.shared.notificationCenter.removeObserver($0) }

        terminationObserver = MainActorResource(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeWindows(forPID: pid)
                if self.observedPID == pid { self.stopWindowObservation() }
            }
        }) { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        refreshWindowObservation()
        recordFrontmostWindow()
    }

    func stop() {
        isRunning = false
        stopWindowObservation()
        observer = nil
        terminationObserver = nil
    }

    func bumpWindow(id: CGWindowID, pid: pid_t) {
        guard !isTrackingSuspended, id != kCGNullWindowID, pid > 0 else { return }
        let key = WindowKey(pid: pid, id: id)
        guard mruWindows.first != key else { return }
        mruWindows.removeAll { $0 == key }
        mruWindows.insert(key, at: 0)
        if mruWindows.count > Self.historyLimit { mruWindows.removeLast() }
    }

    func removeWindows(forPID pid: pid_t) {
        mruWindows.removeAll { $0.pid == pid }
    }

    /// Only observe the foreground app: background main-window changes are not user visits.
    /// Called again on invocation so an initially unavailable AX bridge can recover.
    func refreshWindowObservation() {
        guard isRunning else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            stopWindowObservation()
            return
        }
        let pid = app.processIdentifier
        if observedPID == pid, windowObserver != nil { return }
        stopWindowObservation()
        guard AXIsProcessTrusted() else { return }
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let callback = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { callback.tracker?.recordFrontmostWindow() }
        }, &newObserver)
        guard result == .success, let newObserver else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let callback = CallbackContext(self)
        let context = Unmanaged.passUnretained(callback).toOpaque()
        var subscribed = false
        for notification in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            if AXObserverAddNotification(newObserver, application, notification as CFString, context) == .success {
                subscribed = true
            }
        }
        guard subscribed else { return }
        observedPID = pid
        windowObserver = MainActorResource((observer: newObserver, context: callback)) { resource in
            withExtendedLifetime(resource.context) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(resource.observer), .commonModes)
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func stopWindowObservation() {
        windowObserver = nil
        observedPID = nil
    }

    private func recordFrontmostWindow() {
        guard !isTrackingSuspended,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid == observedPID,
              let id = AXPrivate.focusedWindowID(forPID: pid) else { return }
        bumpWindow(id: id, pid: pid)
    }

    func bump(_ bundleID: String) {
        guard !isTrackingSuspended, mruByBundle.first != bundleID else { return }
        mruByBundle.removeAll { $0 == bundleID }
        mruByBundle.insert(bundleID, at: 0)
    }

    /// Returns the MRU index for a bundle id, or Int.max if not seen.
    func rank(for bundleID: String?) -> Int {
        guard let bundleID, let index = mruByBundle.firstIndex(of: bundleID) else { return .max }
        return index
    }
}
