import SwiftUI

struct WelcomeView: View {
    @ObservedObject var permissions: PermissionsMonitor
    let onFinish: () -> Void

    @AppStorage(Preferences.Key.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false
    @AppStorage(Preferences.Key.showWindowPreviews) private var showWindowPreviews: Bool = true
    @AppStorage(Preferences.Key.includeOtherSpaces) private var includeOtherSpaces: Bool = true
    @AppStorage(Preferences.Key.showMenuBarIcon) private var showMenuBarIcon: Bool = true
    @AppStorage(Preferences.Key.showDockIcon) private var showDockIcon: Bool = false
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
                shortcutsSection
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
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Launch Swiitch at login", isOn: $launchAtLogin)
                Toggle("Show window list for apps with multiple windows", isOn: $showWindowPreviews)
                Toggle("Include windows from other Spaces", isOn: $includeOtherSpaces)
                Divider()
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle("Show Dock icon", isOn: $showDockIcon)
                if !showMenuBarIcon && !showDockIcon {
                    Label(
                        "With both icons hidden, open Swiitch from Finder or Spotlight to reach preferences.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shortcutsSection: some View {
        SectionCard(title: "Shortcuts") {
            VStack(alignment: .leading, spacing: 8) {
                ShortcutRow(keys: "⌘ Tab", description: "Open the switcher / next app")
                ShortcutRow(keys: "⌘ ⇧ Tab", description: "Previous app")
                ShortcutRow(keys: "↓ or `", description: "Show windows of the selected app")
                ShortcutRow(keys: "↑", description: "Back to apps")
                ShortcutRow(keys: "Release ⌘", description: "Switch")
                ShortcutRow(keys: "Esc", description: "Cancel")
            }
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

private struct ShortcutRow: View {
    let keys: String
    let description: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .frame(minWidth: 92, alignment: .leading)
            Text(description)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}
