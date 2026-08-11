import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller. Owned via a singleton so
/// the menu bar "Check for Updates…" item can trigger a check without threading the
/// controller through SwiftUI bindings.
@MainActor
final class UpdateController: NSObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    lazy var updaterController: SPUStandardUpdaterController = {
        // `startingUpdater: true` arms Sparkle on construction so background checks
        // (configured via Info.plist `SUEnableAutomaticChecks`) start scheduling.
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }()

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

    /// A menu-bar utility can reasonably surface Sparkle's standard scheduled reminder.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
