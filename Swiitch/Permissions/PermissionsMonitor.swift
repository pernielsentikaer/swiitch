import AppKit
// The SDK exports the immutable AX prompt key as a mutable C global.
@preconcurrency import ApplicationServices
import CoreGraphics

/// Polls the two TCC permissions Swiitch uses so UI can reflect live state.
///   - Accessibility (required — for the event tap + AX-driven activation).
///   - Screen Recording (optional — for window thumbnails; without it WindowServer withholds
///     window titles, so enumeration falls back to Accessibility titles).
///
/// One shared instance serves the app delegate and every permission view. Accessibility
/// changes can arrive by distributed notification when the privacy list changes; the
/// poll remains a fallback for both permissions, including Screen Recording. Each
/// `CGPreflightScreenCaptureAccess` is an XPC round-trip to `tccd`, so the app-lifetime
/// poll is slow and only a visible permission UI raises the rate. Polling never prompts.
@MainActor
final class PermissionsMonitor: ObservableObject {
    static let shared = PermissionsMonitor()

    /// Best-effort system hint that the Accessibility privacy list changed, for any app.
    nonisolated static let accessibilityChangedNotification = Notification.Name("com.apple.accessibility.api")
    /// The TCC client may still answer from its cache when the notification arrives; a
    /// second read shortly after catches up.
    nonisolated static let accessibilityChangeSettleDelay: TimeInterval = 1.0

    /// Screen Recording only matters for previews and has no change notification; a late
    /// read costs one capture attempt against a stale answer, so the poll can be slow.
    /// Accessibility changes also trigger the notification above when available, and the
    /// event tap's own health check checks for a dead tap every second while active.
    nonisolated static let backgroundInterval: TimeInterval = 10.0
    /// Fast enough that a grant in System Settings is reflected as the user tabs back.
    nonisolated static let foregroundInterval: TimeInterval = 0.8

    @Published private(set) var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published private(set) var screenCaptureGranted: Bool = CGPreflightScreenCaptureAccess()

    private let interval: (background: TimeInterval, foreground: TimeInterval)
    private var timer: Timer?
    private var backgroundActive = false
    private var foregroundRequests = 0
    private var accessibilityObserver: NSObjectProtocol?
    private var settleTask: Task<Void, Never>?
    /// Accessibility change notifications handled since start, for tests and Diagnostics.
    private(set) var accessibilityChangeCount = 0
    var observesAccessibilityChanges: Bool { accessibilityObserver != nil }

    /// Effective polling interval, or nil while idle. Exposed for tests.
    var currentInterval: TimeInterval? {
        if foregroundRequests > 0 { return interval.foreground }
        return backgroundActive ? interval.background : nil
    }

    init(backgroundInterval: TimeInterval = PermissionsMonitor.backgroundInterval,
         foregroundInterval: TimeInterval = PermissionsMonitor.foregroundInterval) {
        interval = (backgroundInterval, foregroundInterval)
    }

    /// App-lifetime polling at the slow interval, plus the Accessibility change notification.
    func start() {
        backgroundActive = true
        if accessibilityObserver == nil {
            accessibilityObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.accessibilityChangedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleAccessibilityChange() }
            }
        }
        refresh()
        reschedule()
    }

    func stop() {
        backgroundActive = false
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        settleTask?.cancel()
        settleTask = nil
        reschedule()
    }

    /// The privacy list changed for some app, possibly this one: read now, and once more
    /// after the TCC cache has had a moment to catch up.
    func handleAccessibilityChange() {
        // Removing an observer does not retract a notification already queued for delivery.
        guard backgroundActive else { return }
        accessibilityChangeCount += 1
        refresh()
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.accessibilityChangeSettleDelay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// A visible permission UI asks for the faster rate; balanced by `endForegroundPolling`.
    func beginForegroundPolling() {
        foregroundRequests += 1
        refresh()
        reschedule()
    }

    func endForegroundPolling() {
        foregroundRequests = max(0, foregroundRequests - 1)
        reschedule()
    }

    /// Reads both permissions now. Publishes only on change.
    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != accessibilityGranted { accessibilityGranted = ax }
        let sc = CGPreflightScreenCaptureAccess()
        if sc != screenCaptureGranted { screenCaptureGranted = sc }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard let interval = currentInterval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // Nothing here needs to fire on the dot; tolerance lets the system coalesce wake-ups.
        timer.tolerance = interval * 0.2
        // `.common` keeps polling alive while a menu or modal tracking loop is running.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Triggers the system prompt + opens the Accessibility pane.
    func requestAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Triggers the system prompt + opens the Screen Recording pane.
    func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
