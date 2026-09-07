import SwiftUI

/// Shared by onboarding and General. Saved intent never overrides the displayed OS state.
struct LoginItemSetting: View {
    let title: String
    @AppStorage(Preferences.Key.launchAtLogin) private var desired = false
    @ObservedObject private var loginItem = LoginItemController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: Binding(
                get: { loginItem.isRequested },
                set: { desired = $0; loginItem.setEnabled($0) }
            ))
            if let message = loginItem.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if loginItem.status == .requiresApproval {
                Text("Approval required in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if loginItem.status == .unavailable {
                Text("Login item unavailable. Keep Swiitch in Applications and try again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loginItem.status == .requiresApproval || loginItem.errorMessage != nil {
                Button("Open Login Items…", action: loginItem.openSettings).controlSize(.small)
            }
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
