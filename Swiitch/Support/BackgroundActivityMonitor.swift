import AppKit

/// Event-driven policy for optional window discovery and preview work. Independent
/// reasons compose: waking a display must not resume work while the session is locked.
@MainActor
final class BackgroundActivityMonitor {
    struct State: Equatable {
        var systemSleeping = false
        var displaysSleeping = false
        var sessionInactive = false
        var screenLocked = false
        var isPaused: Bool { systemSleeping || displaysSleeping || sessionInactive || screenLocked }
    }

    // loginwindow's notifications/key are best-effort, undocumented hints. Missing
    // hints fall back to public display/session events; they never gate user permissions
    // or foreground switching. No private symbol is loaded and no polling is added.
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private let workspace: NotificationCenter
    private let distributed: NotificationCenter
    private let initialState: @MainActor () -> State
    private let onPauseChange: (Bool) -> Void
    private var observers: [MainActorResource<NSObjectProtocol>] = []
    private var generation: UInt64 = 0
    private(set) var state = State()

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributed: NotificationCenter = DistributedNotificationCenter.default(),
         initialState: @escaping @MainActor () -> State = { BackgroundActivityMonitor.currentState() },
         onPauseChange: @escaping (Bool) -> Void) {
        self.workspace = workspace
        self.distributed = distributed
        self.initialState = initialState
        self.onPauseChange = onPauseChange
    }

    func start() {
        guard observers.isEmpty else { return }
        generation &+= 1
        observe(NSWorkspace.willSleepNotification, in: workspace) { $0.systemSleeping = true }
        observe(NSWorkspace.didWakeNotification, in: workspace) { $0.systemSleeping = false }
        observe(NSWorkspace.screensDidSleepNotification, in: workspace) { $0.displaysSleeping = true }
        observe(NSWorkspace.screensDidWakeNotification, in: workspace) { $0.displaysSleeping = false }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: workspace) { $0.sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { $0.sessionInactive = false }
        observe(Self.screenLocked, in: distributed) { $0.screenLocked = true }
        observe(Self.screenUnlocked, in: distributed) { $0.screenLocked = false }
        state = initialState()
        onPauseChange(state.isPaused)
    }

    func stop() {
        generation &+= 1
        observers.removeAll()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter,
                         update: @escaping @MainActor @Sendable (inout State) -> Void) {
        let generation = generation
        let receive: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, !self.observers.isEmpty, self.generation == generation else { return }
            let wasPaused = self.state.isPaused
            update(&self.state)
            if self.state.isPaused != wasPaused { self.onPauseChange(self.state.isPaused) }
        }
        if let distributed = center as? DistributedNotificationCenter {
            // AppKit suspends ordinary distributed delivery while an app is inactive.
            // A menu-bar utility must receive lock/unlock without becoming frontmost.
            let observer = ImmediateDistributedObserver(receive: receive)
            distributed.addObserver(observer, selector: #selector(ImmediateDistributedObserver.receiveNotification(_:)),
                                    name: name, object: nil, suspensionBehavior: .deliverImmediately)
            observers.append(MainActorResource(observer as NSObjectProtocol) { distributed.removeObserver($0) })
        } else {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { receive() }
            }
            observers.append(MainActorResource(token) { center.removeObserver($0) })
        }
    }

    private static func currentState() -> State {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let inactive = (session?[kCGSessionOnConsoleKey as String] as? Bool) == false
            || (session?[kCGSessionLoginDoneKey as String] as? Bool) == false
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) == true
        var count: UInt32 = 0
        var asleep = false
        if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            let capacity = count
            if CGGetOnlineDisplayList(capacity, &displays, &count) == .success, count > 0 {
                asleep = displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
            }
        }
        return State(displaysSleeping: asleep, sessionInactive: inactive, screenLocked: locked)
    }
}

/// Selector-based registration permits `.deliverImmediately` for distributed events.
/// Marshal onto main without assuming which thread the Objective-C caller used.
@MainActor
private final class ImmediateDistributedObserver: NSObject {
    private let receive: @MainActor @Sendable () -> Void

    init(receive: @escaping @MainActor @Sendable () -> Void) { self.receive = receive }

    @objc nonisolated func receiveNotification(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.receive() }
    }
}
