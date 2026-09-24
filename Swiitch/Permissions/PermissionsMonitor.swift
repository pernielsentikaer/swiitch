import AppKit
import ApplicationServices
import CoreGraphics

/// Polls the two TCC permissions Swiitch uses so UI can reflect live state.
///   - Accessibility (required — for the event tap + AX-driven activation).
///   - Screen Recording (optional — for window thumbnails; without it WindowServer withholds
///     window titles, so enumeration falls back to Accessibility titles).
///
/// One shared instance serves the app delegate and every permission view. Each
/// `CGPreflightScreenCaptureAccess` is an XPC round-trip to `tccd`, so the app-lifetime
/// poll is slow and only a visible permission UI raises the rate. Polling never prompts.
@MainActor
final class PermissionsMonitor: ObservableObject {
    static let shared = PermissionsMonitor()

    /// Detects revocation while the user is actively switching, before they retry ⌘+Tab
    /// a few times in vain. The TCC client caches `AXIsProcessTrusted`, so this is cheap.
    nonisolated static let backgroundInterval: TimeInterval = 2.0
    /// Fast enough that a grant in System Settings is reflected as the user tabs back.
    nonisolated static let foregroundInterval: TimeInterval = 0.8

    @Published private(set) var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published private(set) var screenCaptureGranted: Bool = CGPreflightScreenCaptureAccess()

    private let interval: (background: TimeInterval, foreground: TimeInterval)
    private var timer: Timer?
    private var backgroundActive = false
    private var foregroundRequests = 0

    /// Effective polling interval, or nil while idle. Exposed for tests.
    var currentInterval: TimeInterval? {
        if foregroundRequests > 0 { return interval.foreground }
        return backgroundActive ? interval.background : nil
    }

    init(backgroundInterval: TimeInterval = PermissionsMonitor.backgroundInterval,
         foregroundInterval: TimeInterval = PermissionsMonitor.foregroundInterval) {
        interval = (backgroundInterval, foregroundInterval)
    }

    /// App-lifetime polling at the slow interval.
    func start() {
        backgroundActive = true
        refresh()
        reschedule()
    }

    func stop() {
        backgroundActive = false
        reschedule()
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
