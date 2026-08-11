import SwiftUI

@main
struct SwiitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Preferences.Key.showMenuBarIcon) private var showMenuBarIcon: Bool = true

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

            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
            Divider()
            Button("Quit Swiitch") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)
    }
}
