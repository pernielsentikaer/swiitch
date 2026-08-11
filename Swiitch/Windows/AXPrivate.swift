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
