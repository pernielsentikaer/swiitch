import AppKit
import Carbon.HIToolbox

/// Installs a session-level CGEventTap to override Cmd+Tab and drive the SwitcherModel.
///
/// Why a tap instead of `RegisterEventHotKey`:
///  - We need to *swallow* the system Cmd+Tab event so macOS doesn't also show its switcher.
///  - We need to observe modifier *release* (flagsChanged) to commit on Cmd-up.
final class HotkeyManager {
    private let model: SwitcherModel
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private var shiftWasPressed: Bool = false

    init(model: SwitcherModel) {
        self.model = model
    }

    deinit {
        uninstall()
    }

    func install() {
        guard tap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyManager.tapCallback,
            userInfo: refcon
        ) else {
            NSLog("[Swiitch] Failed to create event tap — Accessibility permission likely missing.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source

        startHealthCheck()
        registerWakeObservers()
    }

    func uninstall() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = screensWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        wakeObserver = nil
        screensWakeObserver = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            self.tap = nil
        }
    }

    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("[Swiitch] Event tap was disabled — re-enabling.")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    private func registerWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
        screensWakeObserver = center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reinstallIfNeeded()
        }
    }

    private func reinstallIfNeeded() {
        if let tap, CGEvent.tapIsEnabled(tap: tap) { return }
        uninstall()
        install()
    }

    // MARK: - Tap callback

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        return manager.handle(proxy: proxy, type: type, event: event)
    }

    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable if macOS disabled us for timeout / user input.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        let configured = currentShortcut()
        let currentAppShortcut = currentAppHotkey()

        switch type {
        case .keyDown:
            // Configured all-apps hotkey (default ⌘+Tab). Shift modifier reverses direction.
            if Shortcut.matches(keyCode: keyCode, flags: flags, configured: configured) {
                let shift = flags.contains(.maskShift) && !configured.flags.contains(.maskShift)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.model.isArmed {
                        self.model.arm(reverse: shift)
                    } else {
                        self.model.advance(reverse: shift)
                    }
                }
                return nil // swallow
            }

            // Second hotkey — opens picker straight in current app's windows mode.
            if let appHotkey = currentAppShortcut,
               Shortcut.matches(keyCode: keyCode, flags: flags, configured: appHotkey) {
                let shift = flags.contains(.maskShift) && !appHotkey.flags.contains(.maskShift)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.model.isArmed {
                        self.model.armForCurrentApp(reverse: shift)
                    } else if self.model.mode == .windowsForApp {
                        self.model.advance(reverse: shift)
                    }
                }
                return nil
            }

            // While armed, intercept navigation, filter, and edit keys.
            if model.isArmed, handleKeyWhileArmed(keyCode: keyCode, event: event, flags: flags) {
                return nil
            }

            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Determine the "trigger modifier" — the union of modifiers from whichever
            // hotkey(s) are configured. We commit on release of *any* of them, since the
            // user could have armed with either ⌘+Tab or ⌥+`.
            var triggerMask: CGEventFlags = configured.flags
            if let appHotkey = currentAppShortcut {
                triggerMask.formUnion(appHotkey.flags)
            }
            if triggerMask.isEmpty { triggerMask = .maskCommand }
            let triggerHeld = !flags.intersection(triggerMask).isEmpty
            let shiftHeld = flags.contains(.maskShift)

            // Shift transitions: pressing Shift (without Tab) cycles backward if enabled.
            if model.isArmed && triggerHeld {
                if shiftHeld && !shiftWasPressed
                    && !configured.flags.contains(.maskShift)
                    && !(currentAppShortcut?.flags.contains(.maskShift) ?? false) {
                    let shiftCycles = UserDefaults.standard.bool(forKey: Preferences.Key.shiftCyclesBackwards)
                    if shiftCycles {
                        DispatchQueue.main.async { [weak self] in self?.model.advance(reverse: true) }
                    }
                }
                shiftWasPressed = shiftHeld
            } else {
                shiftWasPressed = false
            }

            // Trigger modifier released while armed → commit.
            if model.isArmed && !triggerHeld {
                DispatchQueue.main.async { [weak self] in
                    self?.model.commit()
                }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Returns true if the key was handled (and should be swallowed).
    private func handleKeyWhileArmed(keyCode: Int, event: CGEvent, flags: CGEventFlags) -> Bool {
        let cmd = flags.contains(.maskCommand)

        // ⌘+W: close the highlighted window. ⌘+H: hide the highlighted app.
        // We swallow these so the underlying app doesn't also receive ⌘W and close its own window.
        if cmd, keyCode == kVK_ANSI_W {
            DispatchQueue.main.async { [weak self] in self?.model.closeSelected() }
            return true
        }
        if cmd, keyCode == kVK_ANSI_H {
            DispatchQueue.main.async { [weak self] in self?.model.hideSelected() }
            return true
        }

        switch keyCode {
        case kVK_Escape:
            DispatchQueue.main.async { [weak self] in self?.model.cancel() }
            return true
        case kVK_Tab:
            DispatchQueue.main.async { [weak self] in self?.model.advance(reverse: false) }
            return true
        case kVK_DownArrow:
            DispatchQueue.main.async { [weak self] in self?.model.advanceRow(reverse: false) }
            return true
        case kVK_UpArrow:
            DispatchQueue.main.async { [weak self] in self?.model.advanceRow(reverse: true) }
            return true
        case kVK_ANSI_Grave:
            DispatchQueue.main.async { [weak self] in self?.model.enterWindowMode() }
            return true
        case kVK_LeftArrow:
            DispatchQueue.main.async { [weak self] in self?.model.advance(reverse: true) }
            return true
        case kVK_RightArrow:
            DispatchQueue.main.async { [weak self] in self?.model.advance(reverse: false) }
            return true
        case kVK_Return:
            DispatchQueue.main.async { [weak self] in self?.model.commit() }
            return true
        case kVK_Delete:
            DispatchQueue.main.async { [weak self] in self?.model.backspaceFilter() }
            return true
        default:
            // Letters / digits / space / hyphen: append to the filter string.
            if let ch = filterCharacter(forKeyCode: keyCode, flags: flags) {
                DispatchQueue.main.async { [weak self] in self?.model.appendFilter(ch) }
                return true
            }
            return false
        }
    }

    /// Convert a raw key event into a filter character. We honor Shift for capitals but
    /// ignore Cmd / Option / Ctrl modifiers in the character mapping itself.
    private func filterCharacter(forKeyCode keyCode: Int, flags: CGEventFlags) -> String? {
        // Use NSEvent to get the localized character — handles non-US layouts for free.
        guard let nsEvent = NSEvent(cgEvent: cgEventFromKeyCode(keyCode, flags: flags)) else { return nil }
        guard let chars = nsEvent.charactersIgnoringModifiers, let first = chars.first else { return nil }
        // Accept letters, digits, space, dot, hyphen. Reject everything else (arrows,
        // function keys, control chars).
        if first.isLetter || first.isNumber || first == " " || first == "." || first == "-" {
            // Honor Shift for capital letters.
            if flags.contains(.maskShift), first.isLetter {
                return String(first).uppercased()
            }
            return String(first)
        }
        return nil
    }

    /// Build a fresh CGEvent with the given keycode/flags (used to invoke NSEvent's
    /// keyboard mapping without polluting the running event stream).
    private func cgEventFromKeyCode(_ keyCode: Int, flags: CGEventFlags) -> CGEvent {
        let src = CGEventSource(stateID: .combinedSessionState)
        let evt = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        evt.flags = flags
        return evt
    }

    /// Reads the configured hotkey from UserDefaults, falling back to ⌘+Tab.
    private func currentShortcut() -> (keyCode: Int, flags: CGEventFlags) {
        let keyCode = UserDefaults.standard.integer(forKey: Preferences.Key.hotkeyKeyCode)
        let rawFlags = UserDefaults.standard.integer(forKey: Preferences.Key.hotkeyModifierFlags)
        let resolvedKey = keyCode == 0 ? kVK_Tab : keyCode
        let resolvedFlags = rawFlags == 0
            ? CGEventFlags.maskCommand
            : CGEventFlags(rawValue: UInt64(rawFlags))
        return (resolvedKey, resolvedFlags)
    }

    /// Returns the second "current-app windows" hotkey when it's enabled, else nil.
    private func currentAppHotkey() -> (keyCode: Int, flags: CGEventFlags)? {
        guard UserDefaults.standard.bool(forKey: Preferences.Key.currentAppHotkeyEnabled) else { return nil }
        let keyCode = UserDefaults.standard.integer(forKey: Preferences.Key.currentAppHotkeyKeyCode)
        let rawFlags = UserDefaults.standard.integer(forKey: Preferences.Key.currentAppHotkeyModifierFlags)
        guard keyCode != 0, rawFlags != 0 else { return nil }
        return (keyCode, CGEventFlags(rawValue: UInt64(rawFlags)))
    }
}
