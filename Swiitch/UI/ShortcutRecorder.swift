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
        HStack(spacing: 12) {
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    Image(systemName: recording ? "keyboard.fill" : "keyboard")
                    Text(recording
                         ? "Press a key…"
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

            Button("Reset") {
                keyCode = defaultKeyCode
                modifierRaw = Int(defaultModifiers.rawValue)
            }
            .controlSize(.small)
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                return nil
            }
            guard event.type == .keyDown else { return event }
            let cgFlags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue))
            let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let usefulFlags = cgFlags.intersection(modifierMask)
            guard !usefulFlags.isEmpty else { return nil }

            self.keyCode = Int(event.keyCode)
            self.modifierRaw = Int(usefulFlags.rawValue)
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = false
    }
}
