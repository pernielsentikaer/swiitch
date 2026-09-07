import Foundation

/// Shared semantics for pointer controls, keyboard commands, and accessibility actions.
enum WindowAction: CaseIterable, Hashable, Sendable {
    case close, minimize, zoom

    var title: String {
        switch self {
        case .close: String(localized: "Close window")
        case .minimize: String(localized: "Minimize window")
        case .zoom: String(localized: "Zoom or restore window")
        }
    }

    var verb: String {
        switch self {
        case .close: String(localized: "close")
        case .minimize: String(localized: "minimize")
        case .zoom: String(localized: "zoom or restore")
        }
    }
}

enum WindowActionAvailability: Equatable, Sendable {
    /// Missing or timed-out AX metadata must not be misrepresented as lack of support.
    case unknown, available, unsupported, disabled

    var canAttempt: Bool { self == .available || self == .unknown }

    func help(for action: WindowAction) -> String {
        switch self {
        case .unknown, .available: action.title
        case .unsupported: String(localized: "\(action.title) — not supported by this window.")
        case .disabled: String(localized: "\(action.title) — currently unavailable.")
        }
    }
}

struct WindowActionCapabilities: Equatable, Sendable {
    var close: WindowActionAvailability = .unknown
    var minimize: WindowActionAvailability = .unknown
    var zoom: WindowActionAvailability = .unknown

    subscript(_ action: WindowAction) -> WindowActionAvailability {
        get {
            switch action {
            case .close: close
            case .minimize: minimize
            case .zoom: zoom
            }
        }
        set {
            switch action {
            case .close: close = newValue
            case .minimize: minimize = newValue
            case .zoom: zoom = newValue
            }
        }
    }
}

/// An accepted AX request is not proof of completion: an unsaved-changes sheet may open.
enum WindowActionResult: Equatable {
    case accepted, permissionRequired, windowGone, unresolved, unsupported, disabled, failed

    func message(for action: WindowAction) -> String? {
        switch self {
        case .accepted: nil
        case .permissionRequired: String(localized: "Accessibility access is needed. Open Swiitch’s General settings.")
        case .windowGone: String(localized: "This window is no longer available.")
        case .unresolved: String(localized: "Couldn’t safely identify this window. Please try again.")
        case .unsupported: String(localized: "\(action.title) isn’t supported by this window.")
        case .disabled: String(localized: "\(action.title) is currently unavailable.")
        case .failed: String(localized: "Couldn’t \(action.verb) this window. Please try again.")
        }
    }
}

/// Capability reads are demand-driven and share a bounded pool even across sessions.
actor WindowActionCapabilityReader {
    static let shared = WindowActionCapabilityReader()
    private let runner = CaptureDeadlineRunner(limit: 2)

    func read(_ window: WindowInfo) async -> WindowActionCapabilities {
        await runner.run(timeout: 0.35) { WindowFocuser.capabilities(for: window) } ?? .init()
    }
}
