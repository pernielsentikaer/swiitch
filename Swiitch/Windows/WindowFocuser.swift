import AppKit
import ApplicationServices

enum WindowFocuser {
    /// Activates an app — used when the user selected an app row without drilling into windows.
    /// We try to raise the app's frontmost window via AX first (so the right window comes forward
    /// in the case where the app has multiple), then activate the app process.
    static func focus(app entry: AppEntry) {
        guard let runningApp = NSRunningApplication(processIdentifier: entry.pid) else { return }

        // Frontmost window for the app = first in CGWindowList's z-order for this pid.
        if let window = entry.windows.first {
            raise(windowID: window.id, pid: entry.pid)
        }

        activate(app: runningApp)
    }

    /// Activates a specific window. Raise FIRST (AX), then activate the app — reversing
    /// this order is racy on macOS 14+ because accessory apps' cross-app activation can
    /// be denied intermittently.
    static func focus(window: WindowInfo) {
        guard let runningApp = NSRunningApplication(processIdentifier: window.pid) else { return }
        raise(windowID: window.id, pid: window.pid)
        activate(app: runningApp)
    }

    /// Close a window via AX. Returns true on success. Mirrors what the user would do
    /// by clicking the red close button — the app gets a chance to prompt for unsaved
    /// changes, etc. (We do NOT force-quit.)
    @discardableResult
    static func close(window: WindowInfo) -> Bool {
        let app = AXUIElementCreateApplication(window.pid)
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement],
            let match = windows.first(where: { AXPrivate.windowID(for: $0) == window.id })
        else { return false }

        var closeButtonValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(match, kAXCloseButtonAttribute as CFString, &closeButtonValue) == .success,
            // swiftlint:disable:next force_cast
            CFGetTypeID(closeButtonValue!) == AXUIElementGetTypeID()
        else { return false }
        let closeButton = closeButtonValue as! AXUIElement
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    /// Hide every window of the app via `NSRunningApplication.hide()`. Like ⌘H from the
    /// Finder. Returns false only if the pid is gone.
    @discardableResult
    static func hide(pid: pid_t) -> Bool {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else { return false }
        return runningApp.hide()
    }

    private static func raise(windowID: CGWindowID, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return }

        guard let match = windows.first(where: { AXPrivate.windowID(for: $0) == windowID }) else {
            return
        }

        // Unminiaturize if needed.
        var minimized: AnyObject?
        if AXUIElementCopyAttributeValue(match, kAXMinimizedAttribute as CFString, &minimized) == .success,
           let isMin = minimized as? Bool, isMin {
            AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }

        AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(match, kAXFocusedAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(match, kAXRaiseAction as CFString)
    }

    private static func activate(app: NSRunningApplication) {
        // On macOS 14+, `NSRunningApplication.activate()` from an `.accessory` (LSUIElement)
        // app is frequently denied for cross-process activation. Avoiding the workaround
        // of toggling our own activation policy (which leaks phantom Dock icons under
        // SwiftUI + `MenuBarExtra`), we use the Accessibility API instead: setting
        // `kAXFrontmostAttribute = true` on the target app's AX element forces it frontmost
        // when we hold Accessibility permission.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        // Belt-and-suspenders: also call `activate()`. On macOS pre-14 this is the only
        // thing that works; on macOS 14+ it's a no-op when AX already brought us forward.
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
