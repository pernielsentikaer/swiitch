import AppKit
import ServiceManagement
import Combine

/// Displays the actual OS state. Refreshing never registers a login item.
@MainActor
final class LoginItemController: ObservableObject {
    enum Status: String {
        case enabled, disabled, requiresApproval, unavailable
    }
    struct Dependencies {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () throws -> Void
        static let live = Self(
            status: {
                switch SMAppService.mainApp.status {
                case .enabled: return .enabled
                case .notRegistered: return .disabled
                case .requiresApproval: return .requiresApproval
                default: return .unavailable
                }
            },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() }
        )
    }

    static let shared = LoginItemController()
    private let dependencies: Dependencies
    @Published private(set) var status: Status
    @Published private(set) var errorMessage: String?
    var isRequested: Bool { status == .enabled || status == .requiresApproval }

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
        status = dependencies.status()
    }

    func refresh() {
        let updated = dependencies.status()
        if status != updated { errorMessage = nil }
        status = updated
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        do {
            if enabled, !isRequested { try dependencies.register() }
            if !enabled, isRequested { try dependencies.unregister() }
            refresh()
        } catch {
            status = dependencies.status()
            errorMessage = String(localized: "Couldn’t change Launch at Login. Try again or check Login Items in System Settings.")
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
