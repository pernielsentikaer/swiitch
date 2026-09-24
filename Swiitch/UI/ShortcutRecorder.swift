import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A small "click to record, press keys" component that captures the next keyDown +
/// modifier flags after the user clicks it, and stores them into the provided UserDefaults
/// keys.
struct ShortcutRecorder: View {
    let keyCodeKey: String
    let modifierFlagsKey: String
    var defaultKeyCode: Int = kVK_Tab
    var defaultModifiers: CGEventFlags = .maskCommand

    @AppStorage private var keyCode: Int
    @AppStorage private var modifierRaw: Int
    @State private var recording: Bool = false
    @State private var monitor: Any?
    @State private var recordingOwner = UUID()
    @State private var validationMessage: String?
    @Environment(\.isEnabled) private var isEnabled
    @ObservedObject private var session = ShortcutRecordingSession.shared
    @AppStorage(Preferences.Key.hotkeyKeyCode) private var primaryKey = 48
    @AppStorage(Preferences.Key.hotkeyModifierFlags) private var primaryFlags = Int(CGEventFlags.maskCommand.rawValue)
    @AppStorage(Preferences.Key.currentAppHotkeyKeyCode) private var secondaryKey = 48
    @AppStorage(Preferences.Key.currentAppHotkeyModifierFlags) private var secondaryFlags = Int(CGEventFlags.maskAlternate.rawValue)
    @AppStorage(Preferences.Key.currentAppHotkeyEnabled) private var currentAppHotkeyEnabled = false

    init(
        keyCodeKey: String,
        modifierFlagsKey: String,
        defaultKeyCode: Int = kVK_Tab,
        defaultModifiers: CGEventFlags = .maskCommand
    ) {
        self.keyCodeKey = keyCodeKey
        self.modifierFlagsKey = modifierFlagsKey
        self.defaultKeyCode = defaultKeyCode
        self.defaultModifiers = defaultModifiers
        self._keyCode = AppStorage(wrappedValue: defaultKeyCode, keyCodeKey)
        self._modifierRaw = AppStorage(wrappedValue: Int(defaultModifiers.rawValue), modifierFlagsKey)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 12) {
                Button(action: toggleRecording) {
                    HStack(spacing: 6) {
                        Image(systemName: recording ? "keyboard.fill" : "keyboard")
                        Text(recording
                             ? String(localized: "Press a key…")
                             : Shortcut.label(keyCode: keyCode, flags: CGEventFlags(rawValue: UInt64(modifierRaw))))
                            .font(.system(.callout, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minWidth: 160, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(recording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recording ? String(localized: "Recording shortcut. Press Escape to cancel.") : String(localized: "Record shortcut"))
                .accessibilityValue(Shortcut.label(keyCode: keyCode, flags: CGEventFlags(rawValue: UInt64(modifierRaw))))

                Button("Reset") {
                    stopRecording()
                    save(key: defaultKeyCode, flags: defaultModifiers)
                }
                .controlSize(.small)
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { stopRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onReceive(session.$owner) { owner in
            if recording, owner != recordingOwner { stopRecording() }
        }
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        validationMessage = nil
        session.begin(owner: recordingOwner) { key, flags in self.captureKey(key, flags: flags) }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else { return event }
            let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue))
            self.captureKey(Int(event.keyCode), flags: cgFlags)
            return nil
        }
    }

    private func captureKey(_ key: Int, flags: CGEventFlags) {
        guard recording else { return }
        if key == kVK_Escape { stopRecording(); return }
        let usefulFlags = flags.intersection(Shortcut.modifierMask)
        guard !usefulFlags.isEmpty else { return }
        if save(key: key, flags: usefulFlags) { stopRecording() }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
        validationMessage = nil
        session.end(owner: recordingOwner)
    }

    @discardableResult
    private func save(key: Int, flags: CGEventFlags) -> Bool {
        let isPrimary = keyCodeKey == Preferences.Key.hotkeyKeyCode
        let other = isPrimary ? (secondaryKey, secondaryFlags) : (primaryKey, primaryFlags)
        // A disabled second hotkey is not listened to, so its stored chord must not block
        // the main shortcut; the conflict warning in General is gated the same way.
        let otherIsActive = isPrimary ? currentAppHotkeyEnabled : true
        guard !otherIsActive || !Shortcut.conflicts((key, flags), (other.0, CGEventFlags(rawValue: UInt64(other.1)))) else {
            validationMessage = String(localized: "Already used by the other shortcut or its Shift-reverse. Choose another combination.")
            return false
        }
        keyCode = key
        modifierRaw = Int(flags.rawValue)
        validationMessage = nil
        return true
    }
}
