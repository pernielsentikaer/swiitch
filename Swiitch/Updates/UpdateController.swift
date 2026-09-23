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
            errorMessage = "The updater couldn’t start. Please try Check for Updates again."
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

    /// A menu-bar utility can reasonably surface Sparkle's standard scheduled reminder.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
