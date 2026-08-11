import AppKit
import SwiftUI

/// Hosts `PreferencesView` in a regular `NSWindow`, owned by the app delegate.
///
/// We deliberately avoid SwiftUI's built-in `Settings` scene + the
/// `showSettingsWindow:` selector — both paths log "Please use SettingsLink for
/// opening the Settings scene." on every invocation. This controller mirrors
/// `WelcomeWindowController` so the menu-bar "Preferences…" item and the Dock
/// reopen handler can both route through it without surfacing that warning.
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            ensureActivatable()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: PreferencesView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Swiitch Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        ensureActivatable()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Ensure the app can show a real window. `.prohibited` is the only policy that
    /// blocks key/main windows; `.accessory` is fine. We don't promote to `.regular`
    /// — `AppDelegate.applyDockIconPreference()` owns that decision via the user's
    /// "Show Dock icon" preference.
    private func ensureActivatable() {
        if NSApp.activationPolicy() == .prohibited {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
