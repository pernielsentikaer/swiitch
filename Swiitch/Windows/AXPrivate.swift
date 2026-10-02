import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Foundation
import os

enum AXPrivate {
    /// Private Accessibility SPI: maps an AXUIElement representing a window to its CGWindowID.
    /// Not allowed for Mac App Store distribution, fine for direct distribution. Resolved at
    /// runtime rather than bound by the linker so a future macOS that renames or removes
    /// it leaves `windowID(for:)` returning nil instead of aborting at launch; every
    /// consumer already treats a missing ID as "unknown".
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            // Without this SPI every app's AX metadata reads as unavailable, which disables
            // ghost-window filtering. Make that state visible instead of silent.
            Logger(subsystem: "com.swiitch.Swiitch", category: "accessibility")
                .error("_AXUIElementGetWindow is unavailable; window identity via Accessibility is disabled")
            return nil
        }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()

    /// Whether the private window-ID SPI resolved at runtime. Reported in diagnostics.
    static var windowIDResolverAvailable: Bool { getWindow != nil }

    /// Deprecated Carbon call, still exported. Resolved the same way for the same reason.
    private typealias GetProcess = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private static let getProcessForPID: GetProcess? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
        return unsafeBitCast(symbol, to: GetProcess.self)
    }()

    private typealias SetFrontProcess = @convention(c) (
        UnsafePointer<ProcessSerialNumber>,
        CGWindowID,
        UInt32
    ) -> CGError

    /// SkyLight is loaded dynamically so a renamed or unavailable private symbol degrades
    /// gracefully instead of preventing Swiitch from launching.
    private struct LibraryHandle: @unchecked Sendable {
        // dlopen/dlsym are thread-safe. This immutable handle is never closed or used
        // to access mutable Swift state; symbols must stay valid for the process lifetime.
        let pointer: UnsafeMutableRawPointer?
    }
    private static let skyLight = LibraryHandle(pointer: dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY | RTLD_LOCAL
    ))

    private static func skyLightSymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = skyLight.pointer, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static let setFrontProcess: SetFrontProcess? =
        skyLightSymbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)

    // MARK: Spaces membership

    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias CopySpacesForWindows = @convention(c) (UInt32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private static let mainConnectionID: MainConnectionID? =
        skyLightSymbol("CGSMainConnectionID", as: MainConnectionID.self)
    private static let copySpacesForWindows: CopySpacesForWindows? =
        skyLightSymbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
    /// kCGSAllSpacesMask: current, other, and fullscreen Spaces alike.
    private static let allSpacesMask: UInt32 = 7

    /// Whether the private Spaces-membership SPI resolved. Reported in diagnostics.
    static var spacesResolverAvailable: Bool { mainConnectionID != nil && copySpacesForWindows != nil }

    /// The Spaces a window is assigned to, or nil when the SPI/query is unavailable.
    /// An ordered-out window can retain Space membership, so this is diagnostic evidence,
    /// not a standalone test of whether the user can reach the window.
    static func spaceIDs(forWindow id: CGWindowID) -> [UInt64]? {
        guard let mainConnectionID, let copySpacesForWindows else { return nil }
        let windows = [NSNumber(value: id)] as CFArray
        guard let result = copySpacesForWindows(mainConnectionID(), allSpacesMask, windows) else { return nil }
        let spaces = result.takeRetainedValue() as? [NSNumber] ?? []
        return spaces.map(\.uint64Value)
    }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var wid: CGWindowID = 0
        return getWindow(element, &wid) == .success ? wid : nil
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
        guard let getProcessForPID, getProcessForPID(pid, &psn) == noErr else { return false }
        let allWindowsAndUserGenerated: UInt32 = 0x100 | 0x200
        return setFrontProcess(&psn, 0, allWindowsAndUserGenerated) == .success
    }
}
