import AppKit
import SwiftUI

enum StartupPresentation: Equatable {
    case none
    case welcome
    case preferences
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: SwitcherPanel?
    private var model: SwitcherModel!
    private var hotkey: HotkeyManager!
    private var focusTracker: FocusTracker!
    private var axMonitorTimer: Timer?
    private var lastAXTrusted: Bool = false
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests load the app executable, which also calls its delegate. Do not
        // arm Sparkle, show onboarding, or install an event tap inside the test runner.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        guard !isRunningTests else {
            return
        }

        Preferences.registerDefaults()
        Preferences.applyAppearance()

        PreferencesWindowController.shared.onVisibilityChange = { [weak self] _ in
            self?.applyDockIconPreference()
        }

        #if !DEBUG
        // Arm Sparkle so its background-check schedule starts.
        // Debug builds intentionally skip automatic checks: their static build number is
        // lower than published releases, which would otherwise offer a same-version update
        // every time a contributor runs from Xcode. Manual checks remain available.
        UpdateController.shared.arm()

        // Sparkle's default scheduled-check cadence is conservative (24h) and the first
        // tick has its own startup delay. For an app users launch and leave running,
        // explicitly kick off a silent background check ~5s after launch so updates are
        // surfaced on the same session they shipped. Silent if nothing's new; pops the
        // standard Sparkle "An update is available" dialog if there is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateController.shared.updaterController.updater.checkForUpdatesInBackground()
        }
        #endif

        applyDockIconPreference()
        observeDefaults()

        focusTracker = FocusTracker()
        focusTracker.start()

        model = SwitcherModel(focusTracker: focusTracker)
        model.onShow = { [weak self] in self?.showPanel() }
        model.onHide = { [weak self] in self?.hidePanel() }
        model.onUpdate = { [weak self] in self?.panel?.refresh() }

        hotkey = HotkeyManager(model: model)

        WelcomeWindowController.shared.onFinish = { [weak self] in
            self?.applyDockIconPreference()
        }

        // Always-on Accessibility monitor handles three cases with one mechanism:
        //  - Initial first-launch grant flow (no AX yet → Welcome opens, polling waits)
        //  - Mid-session revocation (user removes us from Privacy & Security → hotkey
        //    silently breaks, this catches it and re-opens Welcome)
        //  - Re-grant after either of the above
        startAXMonitor()

        let hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: Preferences.Key.hasCompletedOnboarding
        )
        switch Self.startupPresentation(
            hasCompletedOnboarding: hasCompletedOnboarding,
            accessibilityGranted: AXIsProcessTrusted()
        ) {
        case .none:
            break
        case .welcome:
            DispatchQueue.main.async {
                WelcomeWindowController.shared.show()
            }
        case .preferences:
            DispatchQueue.main.async {
                PreferencesWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        axMonitorTimer?.invalidate()
        hotkey?.uninstall()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Dock click / Finder double-click / `open` while we're already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            PreferencesWindowController.shared.show()
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
                Task { @MainActor [weak self] in
                    self?.applyDockIconPreference()
                }
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
        let desired = Self.activationPolicy(
            showDockIcon: UserDefaults.standard.bool(forKey: Preferences.Key.showDockIcon),
            preferencesOpen: PreferencesWindowController.shared.isOpen
        )
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

    nonisolated static func activationPolicy(
        showDockIcon: Bool,
        preferencesOpen: Bool
    ) -> NSApplication.ActivationPolicy {
        showDockIcon || preferencesOpen ? .regular : .accessory
    }

    /// First launch gets onboarding. If a completed installation later loses Accessibility
    /// permission, General Preferences already contains the focused recovery UI; reopening the
    /// entire Welcome flow would incorrectly make an update feel like a fresh installation.
    nonisolated static func startupPresentation(
        hasCompletedOnboarding: Bool,
        accessibilityGranted: Bool
    ) -> StartupPresentation {
        if !hasCompletedOnboarding { return .welcome }
        if !accessibilityGranted { return .preferences }
        return .none
    }

    // MARK: - Accessibility monitor

    /// Polls `AXIsProcessTrusted()` and reacts to transitions. Cheap call (TCC client
    /// caches the answer), and 2s is fast enough that a revocation while the user is
    /// actively using Swiitch is noticed before they retry ⌘+Tab a few times in vain.
    private func startAXMonitor() {
        lastAXTrusted = AXIsProcessTrusted()
        if lastAXTrusted {
            hotkey.install()
        }
        axMonitorTimer?.invalidate()
        axMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAXTrustTransition()
            }
        }
    }

    private func checkAXTrustTransition() {
        let now = AXIsProcessTrusted()
        guard now != lastAXTrusted else { return }
        lastAXTrusted = now

        if now {
            // Re-granted (or granted for the first time). Install the hotkey if it
            // wasn't already running. Safe to call repeatedly — HotkeyManager.install
            // is idempotent (no-ops if already installed).
            hotkey.install()
        } else {
            // Revoked mid-session. The event tap is now dead — ⌘+Tab events won't
            // reach us. Tear it down, cancel any in-progress switcher state, and
            // Show the compact permission recovery UI so the user has a one-click path back
            // to System Settings without being sent through onboarding again.
            hotkey.uninstall()
            model.cancel()
            Task { @MainActor in
                let hasCompletedOnboarding = UserDefaults.standard.bool(
                    forKey: Preferences.Key.hasCompletedOnboarding
                )
                if hasCompletedOnboarding {
                    PreferencesWindowController.shared.show()
                } else {
                    WelcomeWindowController.shared.show()
                }
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
