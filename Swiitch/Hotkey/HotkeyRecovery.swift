import Foundation
import Combine

/// Non-prompting recovery policy, driven on the main run loop. Injection keeps tests
/// independent of actual keyboard taps and the user's Accessibility permission.
final class HotkeyRecovery {
    enum Status: String {
        case stopped, permissionRequired, retrying, ready
    }

    struct Dependencies {
        var trusted: () -> Bool
        var enabled: () -> Bool
        var install: () -> Bool
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    private let dependencies: Dependencies
    private var requested = false
    private var failures = 0
    private var nextAttempt: TimeInterval = 0
    private(set) var status: Status = .stopped
    var onStatus: ((Status) -> Void)?

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func start() {
        guard !requested else { return }
        requested = true
        refresh(force: true)
    }

    func stop() {
        requested = false
        failures = 0
        nextAttempt = 0
        setStatus(.stopped)
    }

    /// Failed attempts back off to at most once per 30 seconds. Wake explicitly retries;
    /// a missing grant only reports state and never invokes a permission prompt.
    func refresh(force: Bool = false) {
        guard requested else { return }
        guard dependencies.trusted() else {
            failures = 0
            nextAttempt = 0
            setStatus(.permissionRequired)
            return
        }
        if dependencies.enabled() {
            failures = 0
            nextAttempt = 0
            setStatus(.ready)
            return
        }
        guard force || dependencies.now() >= nextAttempt else { return }
        if dependencies.install() {
            failures = 0
            nextAttempt = 0
            setStatus(.ready)
        } else {
            failures = min(6, failures + 1)
            nextAttempt = dependencies.now() + min(30, pow(2, Double(failures - 1)))
            setStatus(.retrying)
        }
    }

    private func setStatus(_ value: Status) {
        guard status != value else { return }
        status = value
        onStatus?(value)
    }
}

/// Status only, never a setting. Shared by preferences and the diagnostics report.
final class HotkeyStatus: ObservableObject {
    static let shared = HotkeyStatus()
    @Published var value: HotkeyRecovery.Status = .stopped
}
