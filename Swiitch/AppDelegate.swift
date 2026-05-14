import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: SwitcherPanel?
    private var model: SwitcherModel!
    private var hotkey: HotkeyManager!
    private var focusTracker: FocusTracker!
    private var axPollTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        Preferences.applyAppearance()

        // Touch the Sparkle updater singleton so its background-check schedule arms.
        // The Info.plist flags `SUEnableAutomaticChecks` + `SUFeedURL` drive behavior.
        _ = UpdateController.shared

        applyDockIconPreference()
        observeDefaults()

        focusTracker = FocusTracker()
        focusTracker.start()

        model = SwitcherModel(focusTracker: focusTracker)
        model.onShow = { [weak self] in self?.showPanel() }
        model.onHide = { [weak self] in self?.hidePanel() }
        model.onUpdate = { [weak self] in self?.panel?.refresh() }

        hotkey = HotkeyManager(model: model)

        let needsOnboarding = !UserDefaults.standard.bool(forKey: Preferences.Key.hasCompletedOnboarding)
        if needsOnboarding || !AXIsProcessTrusted() {
            WelcomeWindowController.shared.onFinish = { [weak self] in
                self?.applyDockIconPreference()
                self?.installHotkeyIfPossible()
            }
            DispatchQueue.main.async {
                WelcomeWindowController.shared.show()
            }
        } else {
            installHotkeyIfPossible()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        axPollTimer?.invalidate()
        hotkey?.uninstall()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Dock click / Finder double-click / `open` while we're already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            SwiitchApp.openPreferences()
        }
        return true
    }

    // MARK: - Defaults observation (side effects for preference changes)

    private func observeDefaults() {
        var lastDock = UserDefaults.standard.bool(forKey: Preferences.Key.showDockIcon)
        var lastLogin = UserDefaults.standard.bool(forKey: Preferences.Key.launchAtLogin)
        var lastAppearance = UserDefaults.standard.string(forKey: Preferences.Key.appearance) ?? "system"

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            let dock = UserDefaults.standard.bool(forKey: Preferences.Key.showDockIcon)
            if dock != lastDock {
                lastDock = dock
                self?.applyDockIconPreference()
            }
            let login = UserDefaults.standard.bool(forKey: Preferences.Key.launchAtLogin)
            if login != lastLogin {
                lastLogin = login
                Preferences.syncLaunchAtLogin()
            }
            let appearance = UserDefaults.standard.string(forKey: Preferences.Key.appearance) ?? "system"
            if appearance != lastAppearance {
                lastAppearance = appearance
                Preferences.applyAppearance()
            }
        }
    }

    private func applyDockIconPreference() {
        let desired: NSApplication.ActivationPolicy =
            UserDefaults.standard.bool(forKey: Preferences.Key.showDockIcon) ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)

        // Going .accessory → .regular: the policy IS set but the Dock won't actually
        // surface the icon until something forces a re-evaluation. Activating the app
        // is the standard nudge. (No need on the reverse direction; the Dock removes
        // the icon immediately when we drop to .accessory.)
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Hotkey gating

    private func installHotkeyIfPossible() {
        if AXIsProcessTrusted() {
            hotkey.install()
        } else {
            startAXPolling()
        }
    }

    private func startAXPolling() {
        axPollTimer?.invalidate()
        axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.axPollTimer = nil
                self.hotkey.install()
            }
        }
    }

    // MARK: - Switcher panel

    private func showPanel() {
        if panel == nil {
            panel = SwitcherPanel(model: model)
        }
        panel?.present()
    }

    private func hidePanel() {
        panel?.dismiss()
    }
}
