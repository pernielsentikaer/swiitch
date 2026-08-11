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
    var onVisibilityChange: ((Bool) -> Void)?
    var isOpen: Bool { window != nil }

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
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
        onVisibilityChange?(true)

        ensureActivatable()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A regular activation policy keeps Preferences in the Dock and ⌘-Tab while it
    /// is open. The app delegate restores the user's Dock-icon preference on close.
    private func ensureActivatable() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        onVisibilityChange?(false)
    }
}
