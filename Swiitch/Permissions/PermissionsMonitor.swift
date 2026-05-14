import AppKit
import ApplicationServices
import CoreGraphics

/// Polls the two TCC permissions Swiitch uses so UI can reflect live state.
///   - Accessibility (required — for the event tap + AX-driven activation).
///   - Screen Recording (optional — only for window thumbnails).
@MainActor
final class PermissionsMonitor: ObservableObject {
    @Published private(set) var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published private(set) var screenCaptureGranted: Bool = {
        if #available(macOS 11.0, *) { return CGPreflightScreenCaptureAccess() }
        return true
    }()

    private var timer: Timer?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ax = AXIsProcessTrusted()
                if ax != self.accessibilityGranted {
                    self.accessibilityGranted = ax
                }
                if #available(macOS 11.0, *) {
                    let sc = CGPreflightScreenCaptureAccess()
                    if sc != self.screenCaptureGranted {
                        self.screenCaptureGranted = sc
                    }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Triggers the system prompt + opens the Accessibility pane.
    func requestAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Triggers the system prompt + opens the Screen Recording pane.
    func requestScreenCapture() {
        if #available(macOS 11.0, *) {
            _ = CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
