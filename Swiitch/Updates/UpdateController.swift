import AppKit
import Sparkle
import Combine

/// Thin wrapper around Sparkle's standard updater controller. Owned via a singleton so
/// the menu bar "Check for Updates…" item can trigger a check without threading the
/// controller through SwiftUI bindings.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    struct Backend {
        var readAutomatic: () -> Bool
        var writeAutomatic: (Bool) -> Void
        var start: () throws -> Void
        var checkManually: () -> Void
    }
    static let shared = UpdateController()
    private let injectedBackend: Backend?
    private var started = false
    private var observation: NSKeyValueObservation?
    @Published private(set) var automaticChecksEnabled = false
    @Published private(set) var errorMessage: String?
    /// Display version of a scheduled update Sparkle found while Swiitch was in the
    /// background. Surfaced as a gentle reminder in the menu bar until the user looks at it.
    @Published private(set) var pendingUpdateVersion: String?

    private lazy var updaterController: SPUStandardUpdaterController = {
        // Reading settings in General must not start automatic checks in a Debug build.
        SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }()

    private lazy var backend: Backend = injectedBackend ?? Backend(
        readAutomatic: { [unowned self] in updaterController.updater.automaticallyChecksForUpdates },
        writeAutomatic: { [unowned self] in updaterController.updater.automaticallyChecksForUpdates = $0 },
        start: { [unowned self] in try updaterController.updater.start() },
        checkManually: { [unowned self] in updaterController.checkForUpdates(nil) }
    )

    init(backend: Backend? = nil) {
        injectedBackend = backend
        super.init()
        refreshSettings()
        if backend == nil {
            observation = updaterController.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshSettings() }
            }
        }
    }

    /// Only start Sparkle's preference-aware scheduler. Explicit checks are user actions.
    @discardableResult func arm() -> Bool {
        if started { return true }
        do {
            try backend.start()
            started = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "The updater couldn’t start. Please try Check for Updates again.")
            return false
        }
    }

    func checkForUpdates() {
        guard arm() else { return }
        backend.checkManually()
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        backend.writeAutomatic(enabled)
        refreshSettings()
    }

    func refreshSettings() { automaticChecksEnabled = backend.readAutomatic() }

    // MARK: - Gentle scheduled reminders

    /// Swiitch has no Dock icon, so a scheduled update alert shown behind other apps can go
    /// unnoticed. Sparkle still shows the alert itself when it would be in immediate focus;
    /// otherwise Swiitch records the update and offers it from the menu bar instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            noteScheduledUpdate(version: version, shownBySparkle: handleShowingUpdate)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { clearPendingUpdate() }
    }

    /// Pure state transition, kept separate from the Sparkle callbacks for testing.
    func noteScheduledUpdate(version: String, shownBySparkle: Bool) {
        pendingUpdateVersion = shownBySparkle ? nil : version
    }

    func clearPendingUpdate() {
        pendingUpdateVersion = nil
    }
}
