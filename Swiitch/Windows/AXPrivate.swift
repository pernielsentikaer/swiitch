import ApplicationServices
import Carbon.HIToolbox
import Darwin

/// Private Accessibility SPI: maps an AXUIElement representing a window to its CGWindowID.
/// Note: this is private SPI. Not allowed for Mac App Store distribution,
/// but fine for Developer ID / direct distribution.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum AXPrivate {
    private typealias SetFrontProcess = @convention(c) (
        UnsafePointer<ProcessSerialNumber>,
        CGWindowID,
        UInt32
    ) -> CGError

    /// Loaded dynamically so a renamed or unavailable private SkyLight symbol degrades
    /// gracefully instead of preventing Swiitch from launching.
    private static let setFrontProcess: SetFrontProcess? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetFrontProcess.self)
    }()

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }

    /// The window's Accessibility title, or nil when the app does not publish one.
    /// `kCGWindowName` is withheld without Screen Recording permission, so this is the
    /// only title source for enumeration in that state.
    static func title(for element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String, !title.isEmpty else { return nil }
        return title
    }

    /// Reads an application's Accessibility windows without relying on Swift's
    /// `[AXUIElement]` bridge. Newer macOS versions can return a mutable CFArray that
    /// reports success but fails that conditional cast, making every app appear to have
    /// no AX windows.
    static func windows(forPID pid: pid_t) -> [AXUIElement] {
        availableWindows(forPID: pid) ?? []
    }

    /// Unlike `windows`, preserves an unavailable/failed AX response as nil. A successful
    /// empty array is evidence that the app has no user windows; an AX error is not.
    static func availableWindows(forPID pid: pid_t, timeout: Float = 0.1) -> [AXUIElement]? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        return elements(from: value)
    }

    /// Returns the window the application itself reports as focused. Unlike the order from
    /// `CGWindowListCopyWindowInfo(.optionAll)`, this is authoritative even when an app keeps
    /// multiple overlapping browser windows or hidden host surfaces alive.
    static func focusedWindowID(forPID pid: pid_t) -> CGWindowID? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let element = applicationWindow(forPID: pid, attribute: attribute),
               let id = windowID(for: element) { return id }
        }
        return nil
    }

    static func focusedWindow(forPID pid: pid_t) -> AXUIElement? {
        applicationWindow(forPID: pid, attribute: kAXFocusedWindowAttribute)
            ?? applicationWindow(forPID: pid, attribute: kAXMainWindowAttribute)
    }

    private static func applicationWindow(forPID pid: pid_t, attribute: String) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func focusedWindowFrame(forPID pid: pid_t) -> CGRect? {
        guard let window = focusedWindow(forPID: pid) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.05)
        var position: AnyObject?
        var size: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    static func elements(from value: AnyObject?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = unsafeBitCast(value, to: CFArray.self)
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            return Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
        }
    }

    /// WindowServer-level last resort for Chromium-family apps that ignore both AX and
    /// AppKit activation. Returns false when the private API is unavailable or fails.
    static func windowServerActivate(pid: pid_t) -> Bool {
        guard let setFrontProcess else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard GetProcessForPID(pid, &psn) == noErr else { return false }
        let allWindowsAndUserGenerated: UInt32 = 0x100 | 0x200
        return setFrontProcess(&psn, 0, allWindowsAndUserGenerated) == .success
    }
}
