import AppKit
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?
    private var permissions: PermissionsMonitor?
    var onFinish: (() -> Void)?

    func show() {
        if let window {
            ensureActivatable()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let monitor = PermissionsMonitor()
        monitor.start()
        self.permissions = monitor

        let root = WelcomeView(
            permissions: monitor,
            onFinish: { [weak self] in self?.dismiss() }
        )

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Swiitch"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        ensureActivatable()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.close()
    }

    /// Make sure the app can show a real window. `.prohibited` is the only policy that
    /// blocks key/main windows; `.accessory` is fine. Don't promote to `.regular` here
    /// — AppDelegate is responsible for matching policy to the user's Dock-icon preference.
    private func ensureActivatable() {
        if NSApp.activationPolicy() == .prohibited {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        permissions?.stop()
        permissions = nil
        window = nil
        onFinish?()
    }
}
