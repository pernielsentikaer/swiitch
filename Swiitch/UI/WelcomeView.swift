import SwiftUI

struct WelcomeView: View {
    @ObservedObject var permissions: PermissionsMonitor
    let onFinish: () -> Void

    @AppStorage(Preferences.Key.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false
    @AppStorage(Preferences.Key.launchAtLogin) private var launchAtLogin: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 600)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Swiitch")
                .font(.title.weight(.semibold))
            Text("A native ⌘+Tab replacement that lets you switch between every window — not just apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionsSection
                preferencesSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
    }

    private var permissionsSection: some View {
        SectionCard(title: "Permissions") {
            VStack(alignment: .leading, spacing: 14) {
                permissionRow(
                    granted: permissions.accessibilityGranted,
                    title: "Accessibility access",
                    subtitle: "Required. Lets Swiitch list and raise windows across other apps, and intercept ⌘+Tab.",
                    action: permissions.requestAccessibility
                )
                Divider()
                permissionRow(
                    granted: permissions.screenCaptureGranted,
                    title: "Screen Recording",
                    subtitle: "Optional. Enables live thumbnails of each window in the switcher.",
                    action: permissions.requestScreenCapture
                )
            }
        }
    }

    private func permissionRow(
        granted: Bool,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(granted ? "Granted" : "Open Settings…", action: action)
                .controlSize(.regular)
                .disabled(granted)
        }
    }

    private var preferencesSection: some View {
        SectionCard(title: "Preferences") {
            Toggle("Launch Swiitch at login", isOn: $launchAtLogin)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Get Started") {
                hasCompletedOnboarding = true
                onFinish()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!permissions.accessibilityGranted)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }
}

