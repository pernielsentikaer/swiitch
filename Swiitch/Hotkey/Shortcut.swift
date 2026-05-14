import AppKit
import Carbon.HIToolbox

/// Helpers for rendering a (keyCode, modifier flags) pair as a human-readable label and
/// for matching incoming key events. Modifier flags are stored as raw `CGEventFlags`.
enum Shortcut {
    /// Returns true if `event` is a keyDown matching the configured hotkey.
    static func matches(keyCode: Int, flags: CGEventFlags, configured: (keyCode: Int, flags: CGEventFlags)) -> Bool {
        // Only compare the modifier set we care about (Cmd / Opt / Ctrl / Shift) — ignore
        // device-dependent / NumPad bits which CGEventFlags can include.
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return keyCode == configured.keyCode && (flags.intersection(mask) == configured.flags.intersection(mask))
    }

    /// Pretty label e.g. "⌃ ⌥ ⌘ T".
    static func label(keyCode: Int, flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl)  { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift)    { parts.append("⇧") }
        if flags.contains(.maskCommand)  { parts.append("⌘") }
        parts.append(keyLabel(forKeyCode: keyCode))
        return parts.joined(separator: " ")
    }

    /// Human-readable name for a virtual keycode.
    static func keyLabel(forKeyCode keyCode: Int) -> String {
        switch keyCode {
        case kVK_Tab:        return "Tab"
        case kVK_Space:      return "Space"
        case kVK_Return:     return "Return"
        case kVK_Escape:     return "Esc"
        case kVK_Delete:     return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        case kVK_ANSI_Grave: return "`"
        default: break
        }
        // Letters / digits via TIS keyboard layout.
        if let chars = translate(keyCode: keyCode) {
            return chars.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static func translate(keyCode: Int) -> String? {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            let maxLen = 4
            var actualLen = 0
            var chars = [UniChar](repeating: 0, count: maxLen)
            let result = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                maxLen,
                &actualLen,
                &chars
            )
            guard result == noErr, actualLen > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: actualLen)
        }
    }
}
