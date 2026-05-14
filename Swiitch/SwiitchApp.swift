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
            // SettingsLink is the macOS 14+ SwiftUI way to open the Settings scene.
            // The older `NSApp.sendAction(Selector(("showSettingsWindow:")))` selector
            // is deprecated and prints "Please use SettingsLink for opening the
            // Settings scene." every time it's called.
            SettingsLink {
                Text("Preferences…")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
            Button("Show Welcome…") { WelcomeWindowController.shared.show() }
            Divider()
            Button("Quit Swiitch") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
        }
    }

    static func openPreferences() {
        if NSApp.activationPolicy() == .prohibited {
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
