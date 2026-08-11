import ApplicationServices
import AppKit
import Carbon.HIToolbox

/// Private Accessibility SPI: maps an AXUIElement representing a window to its CGWindowID.
/// Note: this is private SPI. Not allowed for Mac App Store distribution,
/// but fine for Developer ID / direct distribution.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Window-Server-level "set front process" private SPI. Bypasses NSApplication's
/// activation policy checks and the standard AX `kAXFrontmostAttribute` path. The
/// most reliable way to bring a Chromium-based app (Chrome, Arc, Dia, Brave) forward
/// when those layers refuse.
@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafePointer<ProcessSerialNumber>,
    _ windowID: CGWindowID,
    _ mode: UInt32
) -> CGError

/// Convert a Unix pid to the legacy Carbon ProcessSerialNumber that the WindowServer
/// SPIs require.
@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum AXPrivate {
    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }

    /// Activate a process at the Window Server level. Useful as a fallback when the
    /// standard AX + `NSRunningApplication.activate()` path doesn't bring the target
    /// forward — Chromium browsers in particular ignore those layers in some states.
    ///
    /// Mode bits used:
    ///   - `kCPSAllWindows` (0x100): bring all of the app's windows forward, not just one
    ///   - `kCPSUserGenerated` (0x200): mark this as a user-initiated activation so the
    ///     WindowServer treats it like a real click/keystroke instead of a programmatic
    ///     change (otherwise some apps will refuse / revert).
    static func windowServerActivate(pid: pid_t) {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard GetProcessForPID(pid, &psn) == noErr else { return }
        _ = _SLPSSetFrontProcessWithOptions(&psn, 0, 0x100 | 0x200)
    }
}
