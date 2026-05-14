import ApplicationServices

/// Private Accessibility SPI: maps an AXUIElement representing a window to its CGWindowID.
/// Note: this is private SPI. Not allowed for Mac App Store distribution,
/// but fine for Developer ID / direct distribution.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AXPrivate {
    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
    }
}
