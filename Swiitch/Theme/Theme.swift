import SwiftUI

/// Custom environment key for our accent color. We can't rely on `.tint()` propagating to
/// `Color.accentColor` literal references on macOS — only controls (`Button`, `Toggle` etc.)
/// pick up the tint. By reading `@Environment(\.swiitchAccent)` everywhere, the user's
/// chosen accent reliably reaches selection highlights, cell borders, and so on.
private struct SwiitchAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var swiitchAccent: Color {
        get { self[SwiitchAccentKey.self] }
        set { self[SwiitchAccentKey.self] = newValue }
    }
}

enum Theme {
    /// Build the switcher panel's background view based on the user's material preference.
    @ViewBuilder
    static func panelBackground(material: Preferences.PanelMaterial, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch material {
        case .translucentLight:
            shape.fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        case .translucent:
            shape.fill(.regularMaterial)
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        case .frosted:
            shape.fill(.thickMaterial)
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        case .solid:
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        case .solidLight:
            shape.fill(Color(white: 0.94))
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        case .solidDark:
            shape.fill(Color(white: 0.12))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
        }
    }
}
