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
    nonisolated static let frameAutosaveName = "Swiitch.Preferences"

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
        window.title = "Swiitch"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        Self.restoreFrame(of: window, autosaveName: Self.frameAutosaveName)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
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
        window?.saveFrame(usingName: Self.frameAutosaveName)
        // A new window will own this autosave name on the next open.
        window?.setFrameAutosaveName("")
        window = nil
        onVisibilityChange?(false)
    }

    /// AppKit restores screen-relative geometry (including display changes). First use
    /// retains the normal centered size; subsequent opens honor the user's last frame.
    static func restoreFrame(of window: NSWindow, autosaveName: String) {
        window.setContentSize(NSSize(width: 780, height: 600))
        window.minSize = NSSize(width: 720, height: 520)
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
    }
}
