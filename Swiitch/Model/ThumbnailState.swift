import Foundation

/// Presentation only: capture availability never changes which windows can be switched to.
enum ThumbnailState: Equatable, CaseIterable {
    case loading
    case ready
    case unavailable
    case permissionRequired

    var label: String {
        switch self {
        case .loading: return String(localized: "Loading preview…")
        case .ready, .unavailable: return String(localized: "Preview unavailable")
        case .permissionRequired: return String(localized: "Screen Recording needed")
        }
    }

    var symbol: String {
        switch self {
        case .loading: return "hourglass"
        case .ready, .unavailable: return "photo"
        case .permissionRequired: return "lock.shield"
        }
    }

    var help: String {
        switch self {
        case .loading: return String(localized: "Capturing a preview. You can switch to this window now.")
        case .ready, .unavailable: return String(localized: "A preview could not be captured. Swiitch retries automatically; you can still switch to this window.")
        case .permissionRequired: return String(localized: "Enable Screen Recording in Swiitch Preferences → General to show previews. Window switching still works without it.")
        }
    }
}
