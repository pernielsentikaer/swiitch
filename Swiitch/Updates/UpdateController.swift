import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller. Owned via a singleton so
/// the menu bar "Check for Updates…" item can trigger a check without threading the
/// controller through SwiftUI bindings.
@MainActor
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    /// `lazy` so we can pass `self` as the user-driver delegate. (Sparkle's init takes
    /// the delegate at construction time, and `self` isn't available before super.init.)
    lazy var updaterController: SPUStandardUpdaterController = {
        // `startingUpdater: true` arms Sparkle on construction so background checks
        // (configured via Info.plist `SUEnableAutomaticChecks`) start scheduling.
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }()

    /// Force eager construction. Call this once at app launch so the updater + its
    /// scheduled-check timer actually arms; otherwise Sparkle stays dormant until
    /// someone touches `updaterController`.
    func arm() {
        _ = updaterController
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticChecksEnabled: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Tell Sparkle we're aware of background-presentation considerations. For a
    /// menu-bar utility, the standard "An update is available" window IS a reasonable
    /// gentle reminder — it pops as a regular `NSWindow` that the user notices when
    /// they're at their Mac. Returning true silences the
    /// "does not implement gentle reminders" warning Sparkle logs on startup.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
