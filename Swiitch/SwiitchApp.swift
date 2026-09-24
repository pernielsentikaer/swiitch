import SwiftUI

@main
struct SwiitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Preferences.Key.showMenuBarIcon) private var showMenuBarIcon: Bool = true
    @ObservedObject private var updates = UpdateController.shared

    var body: some Scene {
        MenuBarExtra(
            "Swiitch",
            systemImage: "rectangle.stack",
            isInserted: $showMenuBarIcon
        ) {
            // Route Preferences through our own NSWindow-hosted controller. The
            // SwiftUI `Settings` scene + `showSettingsWindow:` selector both log
            // "Please use SettingsLink for opening the Settings scene." even when
            // invoked from a SettingsLink itself in some scenarios. Owning the
            // window outright sidesteps the warning entirely.
            Button("Preferences…") { PreferencesWindowController.shared.show() }
                .keyboardShortcut(",", modifiers: .command)

            if let version = updates.pendingUpdateVersion {
                // Gentle reminder for a scheduled update found while Swiitch was in the
                // background; checking again brings Sparkle's alert into focus.
                Button(String(localized: "Update to \(version) Available…")) { UpdateController.shared.checkForUpdates() }
            } else {
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
            }
            Divider()
            Button("Quit Swiitch") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)
    }
}
