import AppKit
import ApplicationServices

/// Makes discovery event-driven. Accessibility observers on every regular app report
/// window creation, destruction, minimize/restore, move/resize, and title changes;
/// NSWorkspace reports launches, terminations, hide/unhide; Spaces and display changes
/// count too. Every event coalesces into one fresh background collection, so the cached
/// list is current by construction. While every live app is covered, opening the picker can
/// reuse that cache instead of collecting again, and the periodic poll becomes a safety net.
/// Nothing here reads window contents; it only learns that something changed.
@MainActor
final class WindowEventMonitor {
    struct Dependencies {
        var trusted: () -> Bool = { AXIsProcessTrusted() }
        var refresh: @MainActor () async -> Void
        /// Creates the per-app observer; nil when the app's Accessibility bridge refuses.
        var observeApplication: @MainActor (pid_t, WindowEventMonitor) -> AppObservation?
            = { pid, monitor in AppObservation(pid: pid, monitor: monitor) }
        /// The app's Accessibility windows, resolved to WindowServer IDs.
        var windowElements: (pid_t) -> [(CGWindowID, AXUIElement)] = { pid in
            (AXPrivate.availableWindows(forPID: pid, timeout: 0.03) ?? []).compactMap { element in
                AXPrivate.windowID(for: element).map { ($0, element) }
            }
        }
    }

    /// One app's observer plus the windows it is subscribed to.
    final class AppObservation {
        let pid: pid_t
        private(set) var observer: AXObserver?
        /// The switchable windows this observation is meant to cover (from the last collection).
        private(set) var trackedWindowIDs: Set<CGWindowID> = []
        /// The subset whose Accessibility element accepted notifications.
        private var windowElements: [CGWindowID: AXUIElement] = [:]
        var subscribedWindowCount: Int { windowElements.count }

        static let applicationNotifications = [
            kAXWindowCreatedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification,
        ]
        static let windowNotifications = [
            kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
            kAXWindowMovedNotification, kAXWindowResizedNotification,
        ]

        /// Test seam: an observation that subscribes to nothing.
        init(pid: pid_t) { self.pid = pid }

        init?(pid: pid_t, monitor: WindowEventMonitor) {
            self.pid = pid
            var created: AXObserver?
            let status = AXObserverCreate(pid, { _, _, notification, context in
                guard let context else { return }
                let monitor = Unmanaged<WindowEventMonitor>.fromOpaque(context).takeUnretainedValue()
                // The observer's run-loop source lives on the main run loop.
                MainActor.assumeIsolated { monitor.handle(notification as String) }
            }, &created)
            guard status == .success, let created else { return nil }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.05)
            let context = Unmanaged.passUnretained(monitor).toOpaque()
            var subscribed = false
            for notification in Self.applicationNotifications {
                if AXObserverAddNotification(created, application, notification as CFString, context) == .success {
                    subscribed = true
                }
            }
            guard subscribed else { return nil }
            observer = created
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }

        /// Tracks `windowIDs`: forgets closed windows, subscribes new ones whose element is
        /// available. Already-subscribed windows keep their element so notifications continue.
        func observe(windowIDs: Set<CGWindowID>, elements: [(CGWindowID, AXUIElement)], monitor: WindowEventMonitor) {
            for id in trackedWindowIDs.subtracting(windowIDs) {
                if let observer, let element = windowElements.removeValue(forKey: id) {
                    for notification in Self.windowNotifications {
                        AXObserverRemoveNotification(observer, element, notification as CFString)
                    }
                }
            }
            if let observer {
                let context = Unmanaged.passUnretained(monitor).toOpaque()
                for (id, element) in elements where windowIDs.contains(id) && windowElements[id] == nil {
                    AXUIElementSetMessagingTimeout(element, 0.02)
                    var subscribed = false
                    for notification in Self.windowNotifications {
                        if AXObserverAddNotification(observer, element, notification as CFString, context) == .success {
                            subscribed = true
                        }
                    }
                    if subscribed { windowElements[id] = element }
                }
            }
            trackedWindowIDs = windowIDs
        }

        func stop() {
            guard let observer else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            self.observer = nil
            windowElements.removeAll()
            trackedWindowIDs.removeAll()
        }
    }

    /// Events inside this window collapse into one refresh.
    static let coalescingInterval: TimeInterval = 0.05

    private let dependencies: Dependencies
    private var observations: [pid_t: AppObservation] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?
    private(set) var isActive = false
    private(set) var eventCount = 0
    private(set) var refreshCount = 0
    /// True when every app in the last collection has a working observer, so a cached
    /// snapshot with no events since is current by construction.
    private(set) var coversEveryApp = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Observed apps and windows; reported in diagnostics.
    var observedApplicationCount: Int { observations.count }
    var trackedWindowCount: Int { observations.values.reduce(0) { $0 + $1.trackedWindowIDs.count } }
    var subscribedWindowCount: Int { observations.values.reduce(0) { $0 + $1.subscribedWindowCount } }

    /// Plain counts for the diagnostics report.
    struct Statistics: Equatable {
        let active: Bool
        let coversEveryApp: Bool
        let observedApps: Int
        let subscribedWindows: Int
        let events: Int
        let refreshes: Int
    }

    var statistics: Statistics {
        Statistics(active: isActive, coversEveryApp: coversEveryApp, observedApps: observedApplicationCount,
                   subscribedWindows: subscribedWindowCount, events: eventCount, refreshes: refreshCount)
    }

    func start() {
        guard !isActive, dependencies.trusted() else { return }
        isActive = true
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didTerminateApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self?.forget(pid: app.processIdentifier)
                    }
                    self?.handle(name.rawValue)
                }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle("screenParameters") }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        coversEveryApp = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observation in observations.values { observation.stop() }
        observations.removeAll()
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    /// After each collection: observe apps that are new, drop apps that are gone, and
    /// subscribe the switchable windows of apps whose window set changed.
    func reconcile(with collection: WindowEnumerator.Collection) {
        guard isActive else { return }
        let live = Dictionary(uniqueKeysWithValues: collection.apps.map { ($0.pid, Set($0.windows.map(\.id))) })
        for pid in observations.keys where live[pid] == nil { forget(pid: pid) }
        var uncovered = 0
        for (pid, windowIDs) in live {
            let observation: AppObservation
            if let existing = observations[pid] {
                observation = existing
            } else if let created = dependencies.observeApplication(pid, self) {
                observations[pid] = created
                observation = created
            } else {
                uncovered += 1
                continue
            }
            if observation.observer == nil { uncovered += 1 }
            guard observation.trackedWindowIDs != windowIDs else { continue }
            let elements = observation.observer == nil ? [] : dependencies.windowElements(pid)
            observation.observe(windowIDs: windowIDs, elements: elements, monitor: self)
        }
        coversEveryApp = uncovered == 0
    }

    /// Any change notification: coalesce into one refresh shortly after the last event.
    func handle(_ notification: String) {
        guard isActive else { return }
        eventCount += 1
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.coalescingInterval))
            guard !Task.isCancelled, let self else { return }
            self.pendingRefresh = nil
            self.refreshCount += 1
            await self.dependencies.refresh()
        }
    }

    private func forget(pid: pid_t) {
        observations.removeValue(forKey: pid)?.stop()
    }
}
