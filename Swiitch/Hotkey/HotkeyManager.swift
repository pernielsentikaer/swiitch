import AppKit
import Carbon.HIToolbox

/// Installs a session-level CGEventTap to override Cmd+Tab and drive the SwitcherModel.
///
/// Why a tap instead of `RegisterEventHotKey`:
///  - We need to *swallow* the system Cmd+Tab event so macOS doesn't also show its switcher.
///  - We need to observe modifier *release* (flagsChanged) to commit on Cmd-up.
final class HotkeyManager {
    private let model: SwitcherModel
    private let defaults: UserDefaults
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private let recording: ShortcutRecordingSession
    private var recordingObserver: NSObjectProtocol?
    /// Tracks whether `recovery` was ever created, so deinit can report a stopped status
    /// without instantiating the lazy controller.
    private var recoveryStarted = false
    private lazy var recovery: HotkeyRecovery = {
        let controller = HotkeyRecovery(dependencies: .init(
            trusted: { AXIsProcessTrusted() },
            enabled: { [weak self] in self?.tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false },
            install: { [weak self] in self?.createOrEnableTap() ?? false }
        ))
        controller.onStatus = { HotkeyStatus.shared.value = $0 }
        return controller
    }()
    /// Input is accepted synchronously on the main-runloop tap, before UI work is queued.
    /// Separate input/presented sessions preserve quick press-release-press ordering.
    private final class Session {
        let modifiers: CGEventFlags
        var pending = true
        var shiftWasPressed: Bool
        var advancedOnShiftPress = false

        init(modifiers: CGEventFlags, flags: CGEventFlags) {
            self.modifiers = modifiers.intersection(Shortcut.modifierMask)
            shiftWasPressed = flags.contains(.maskShift)
        }
    }

    private struct HotkeyMatch {
        let modifiers: CGEventFlags
        let direction: Shortcut.Direction
        let currentAppOnly: Bool
    }

    private var inputSession: Session?
    private var presentedSession: Session?
    private var dispatchGeneration: UInt64 = 0
    private var preparingSnapshot = false
    private var queuedOperations: [() -> Void] = []

    init(model: SwitcherModel, defaults: UserDefaults = .standard,
         recording: ShortcutRecordingSession = .shared) {
        self.model = model
        self.defaults = defaults
        self.recording = recording
        recordingObserver = NotificationCenter.default.addObserver(
            forName: ShortcutRecordingSession.didBegin, object: recording, queue: .main
        ) { [weak self] _ in self?.cancelInputSession() }
    }

    deinit {
        // Tear down system resources only. `uninstall()` would force the lazy recovery
        // controller into existence with `[weak self]` captures of an object mid-deinit,
        // and cancel the model as a deallocation side effect.
        healthCheckTimer?.invalidate()
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = screensWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        removeTap()
        if recoveryStarted { recovery.stop() }
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
    }

    func install() {
        if healthCheckTimer == nil { startHealthCheck() }
        if wakeObserver == nil { registerWakeObservers() }
        recoveryStarted = true
        recovery.start()
    }

    private func createOrEnableTap() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            removeTap()
        }

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
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source

        return CGEvent.tapIsEnabled(tap: tap)
    }

    func uninstall() {
        recovery.stop()
        cancelInputSession()
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = screensWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        wakeObserver = nil
        screensWakeObserver = nil
        removeTap()
    }

    private func cancelInputSession() {
        dispatchGeneration &+= 1
        preparingSnapshot = false
        queuedOperations.removeAll()
        inputSession = nil
        presentedSession = nil
        model.cancel()
    }

    private func removeTap() {
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
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recovery.refresh()
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
        recovery.refresh(force: true)
    }

    // MARK: - Tap callback

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
        return manager.handle(type: type, event: event)
    }

    /// Internal entry point also used by synthetic-event tests; never posts input events.
    func handle(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable if macOS disabled us for timeout / user input.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if recording.isRecording {
            if type == .keyDown, recording.consume(
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags
            ) { return nil }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // A mouse click or external cancellation can end the model's session without a
        // keyboard release. Pending opening work is deliberately not treated as closed.
        if let session = inputSession, !session.pending, !model.isArmed {
            inputSession = nil
        }

        switch type {
        case .keyDown:
            if let match = matchingHotkey(keyCode: keyCode, flags: flags) {
                if let session = inputSession {
                    advance(session, reverse: match.direction == .reverse, currentAppOnly: match.currentAppOnly)
                } else {
                    beginSession(match, flags: flags)
                }
                return nil // swallow
            }

            // Pending sessions intercept navigation too, so Esc/Tab immediately after
            // the first hotkey are ordered behind its queued opening operation.
            if let session = inputSession,
               handleKeyWhileArmed(keyCode: keyCode, flags: flags, session: session) {
                return nil
            }

            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            guard let session = inputSession else { return Unmanaged.passUnretained(event) }
            // Releasing any required modifier ends this chord. Optional reverse Shift,
            // and modifiers belonging only to another configured shortcut, do not hold it.
            if flags.intersection(session.modifiers) != session.modifiers {
                finishSession(session, cancel: false)
                return Unmanaged.passUnretained(event)
            }

            let shiftHeld = flags.contains(.maskShift)
            if shiftHeld && !session.shiftWasPressed && !session.modifiers.contains(.maskShift)
                && defaults.bool(forKey: Preferences.Key.shiftCyclesBackwards) {
                session.advancedOnShiftPress = true
                enqueue(for: session) { $0.model.advance(reverse: true) }
            }
            if !shiftHeld { session.advancedOnShiftPress = false }
            session.shiftWasPressed = shiftHeld
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Exact bindings take precedence over another binding's optional reverse variant.
    private func matchingHotkey(keyCode: Int, flags: CGEventFlags) -> HotkeyMatch? {
        var matches: [HotkeyMatch] = []
        let primary = currentShortcut()
        if let direction = Shortcut.matchingDirection(keyCode: keyCode, flags: flags, configured: primary) {
            matches.append(HotkeyMatch(modifiers: primary.flags, direction: direction, currentAppOnly: false))
        }
        if let secondary = currentAppHotkey(),
           let direction = Shortcut.matchingDirection(keyCode: keyCode, flags: flags, configured: secondary) {
            matches.append(HotkeyMatch(modifiers: secondary.flags, direction: direction, currentAppOnly: true))
        }
        return matches.first { $0.direction == .forward } ?? matches.first
    }

    private func beginSession(_ match: HotkeyMatch, flags: CGEventFlags) {
        let session = Session(modifiers: match.modifiers, flags: flags)
        inputSession = session
        let generation = dispatchGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dispatchGeneration == generation else { return }
            self.performWhenPrepared { [weak self] in
                guard let self, self.dispatchGeneration == generation else { return }
                self.preparingSnapshot = true
                self.presentedSession = session
                self.model.prepareForArm { [weak self] in
                    guard let self, self.dispatchGeneration == generation else { return }
                    let reverse = match.direction == .reverse
                    if self.model.isArmed {
                        if !match.currentAppOnly || self.model.mode == .currentAppWindows {
                            self.model.advance(reverse: reverse)
                        }
                    } else if match.currentAppOnly {
                        self.model.armForCurrentApp(reverse: reverse)
                    } else {
                        self.model.arm(reverse: reverse)
                    }
                    guard self.dispatchGeneration == generation else {
                        self.model.cancel()
                        return
                    }
                    session.pending = false
                    if !self.model.isArmed {
                        if self.inputSession === session { self.inputSession = nil }
                        self.presentedSession = nil
                    }
                    self.preparingSnapshot = false
                    self.drainPreparedOperations()
                }
            }
        }
    }

    private func performWhenPrepared(_ operation: @escaping () -> Void) {
        if preparingSnapshot { queuedOperations.append(operation) }
        else { operation() }
    }

    private func drainPreparedOperations() {
        while !preparingSnapshot, !queuedOperations.isEmpty {
            queuedOperations.removeFirst()()
        }
    }

    /// Only work belonging to the presented session may mutate its model. In particular,
    /// teardown/uninstall invalidates queued work without affecting a later session.
    private func enqueue(for session: Session, action: @escaping (HotkeyManager) -> Void) {
        let generation = dispatchGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dispatchGeneration == generation else { return }
            self.performWhenPrepared { [weak self] in
                guard let self, self.dispatchGeneration == generation,
                      self.presentedSession === session, self.model.isArmed else { return }
                action(self)
            }
        }
    }

    private func advance(_ session: Session, reverse: Bool, currentAppOnly: Bool = false) {
        // When Shift itself already moved backward, the following Shift-Tab completes
        // that same gesture. Further Tabs while Shift is held still move backward.
        let alreadyAdvanced = reverse && session.advancedOnShiftPress
        session.advancedOnShiftPress = false
        guard !alreadyAdvanced else { return }
        enqueue(for: session) {
            guard !currentAppOnly || $0.model.mode == .currentAppWindows else { return }
            $0.model.advance(reverse: reverse)
        }
    }

    private func finishSession(_ session: Session, cancel: Bool) {
        if inputSession === session { inputSession = nil }
        enqueue(for: session) {
            if cancel { $0.model.cancel() } else { $0.model.commit() }
            $0.presentedSession = nil
        }
    }

    /// Returns true if the key was handled (and should be swallowed).
    private func handleKeyWhileArmed(keyCode: Int, flags: CGEventFlags, session: Session) -> Bool {
        if keyCode != kVK_Tab { session.advancedOnShiftPress = false }

        // Command is normally held to keep the picker open, so ⌘H/⌘W must remain
        // search letters. Window actions require an explicit Control-Command chord,
        // with at least one of those modifiers added beyond the opening shortcut.
        // A custom shortcut already holding both must keep H/W searchable too.
        let actionModifiers: CGEventFlags = [.maskControl, .maskCommand]
        let isWindowAction = flags.intersection(actionModifiers) == actionModifiers
            && !actionModifiers.subtracting(session.modifiers).isEmpty
        if isWindowAction, keyCode == kVK_ANSI_W {
            enqueue(for: session) { $0.model.closeSelected() }
            return true
        }
        if isWindowAction, keyCode == kVK_ANSI_H {
            enqueue(for: session) { $0.model.hideSelected() }
            return true
        }

        switch keyCode {
        case kVK_Escape:
            finishSession(session, cancel: true)
            return true
        case kVK_Tab:
            advance(session, reverse: flags.contains(.maskShift) && !session.modifiers.contains(.maskShift))
            return true
        case kVK_DownArrow:
            enqueue(for: session) { $0.model.advanceRow(reverse: false) }
            return true
        case kVK_UpArrow:
            enqueue(for: session) { $0.model.advanceRow(reverse: true) }
            return true
        case kVK_ANSI_Grave:
            enqueue(for: session) { $0.model.enterWindowMode() }
            return true
        case kVK_LeftArrow:
            enqueue(for: session) { $0.model.advance(reverse: true) }
            return true
        case kVK_RightArrow:
            enqueue(for: session) { $0.model.advance(reverse: false) }
            return true
        case kVK_Return:
            finishSession(session, cancel: false)
            return true
        case kVK_Delete:
            enqueue(for: session) { $0.model.backspaceFilter() }
            return true
        default:
            // Printable search text, including punctuation, belongs to Swiitch while
            // the shortcut is held. Otherwise e.g. Command-comma leaks to the app below.
            if let ch = filterCharacter(forKeyCode: keyCode, flags: flags) {
                enqueue(for: session) { $0.model.appendFilter(ch) }
                return true
            }
            // Preserve existing pass-through for non-text keys such as function keys.
            return false
        }
    }

    /// Convert a raw key event into a filter character. We honor Shift for capitals but
    /// ignore Cmd / Option / Ctrl modifiers in the character mapping itself.
    private func filterCharacter(forKeyCode keyCode: Int, flags: CGEventFlags) -> String? {
        // Use NSEvent to get the localized character — handles non-US layouts for free.
        guard let cgEvent = cgEventFromKeyCode(keyCode, flags: flags),
              let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        guard let chars = nsEvent.charactersIgnoringModifiers, let first = chars.first else { return nil }
        // Navigation is handled above. Accept printable punctuation/symbols too, but
        // not control characters or AppKit's private-use function-key characters.
        if first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol || first == " " {
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
    /// Runs inside the event-tap callback; a failed allocation must drop the character,
    /// never crash the tap.
    private func cgEventFromKeyCode(_ keyCode: Int, flags: CGEventFlags) -> CGEvent? {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let evt = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
            return nil
        }
        evt.flags = flags
        return evt
    }

    /// Reads the configured hotkey from UserDefaults, falling back to ⌘+Tab.
    private func currentShortcut() -> (keyCode: Int, flags: CGEventFlags) {
        let keyCode = defaults.integer(forKey: Preferences.Key.hotkeyKeyCode)
        let rawFlags = defaults.integer(forKey: Preferences.Key.hotkeyModifierFlags)
        return Self.configuredShortcut(keyCode: keyCode, rawFlags: rawFlags)
            ?? (kVK_Tab, .maskCommand)
    }

    /// Returns the second "current-app windows" hotkey when it's enabled, else nil.
    private func currentAppHotkey() -> (keyCode: Int, flags: CGEventFlags)? {
        guard defaults.bool(forKey: Preferences.Key.currentAppHotkeyEnabled) else { return nil }
        let keyCode = defaults.integer(forKey: Preferences.Key.currentAppHotkeyKeyCode)
        let rawFlags = defaults.integer(forKey: Preferences.Key.currentAppHotkeyModifierFlags)
        return Self.configuredShortcut(keyCode: keyCode, rawFlags: rawFlags)
    }

    /// Virtual key code zero is the ANSI A key, so only a missing modifier can make a
    /// shortcut invalid. Registered defaults provide the primary fallback values.
    static func configuredShortcut(
        keyCode: Int,
        rawFlags: Int
    ) -> (keyCode: Int, flags: CGEventFlags)? {
        guard rawFlags != 0 else { return nil }
        return (keyCode, CGEventFlags(rawValue: UInt64(rawFlags)))
    }
}
