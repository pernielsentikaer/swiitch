import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller. Owned via a singleton so
/// the menu bar "Check for Updates…" item can trigger a check without threading the
/// controller through SwiftUI bindings.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    let updaterController: SPUStandardUpdaterController

    private init() {
        // `startingUpdater: true` arms Sparkle on construction so background checks
        // (configured via Info.plist `SUEnableAutomaticChecks`) start scheduling.
        // We don't supply custom delegates — Sparkle's defaults handle the standard
        // "show update dialog, download, restart" flow without intervention. Add an
        // SPUUpdaterDelegate later only if we need to customize behavior (e.g.
        // signed-update channel selection, pre-flight conditions).
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticChecksEnabled: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }
}
