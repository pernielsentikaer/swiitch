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
    /// Fixed backgrounds need matching semantic text/icon colors. Adaptive materials
    /// inherit the app/system choice, rather than imposing their own appearance.
    static func panelColorScheme(material: Preferences.PanelMaterial, inherited: ColorScheme) -> ColorScheme {
        switch material {
        case .solidLight: return .light
        case .solidDark: return .dark
        case .translucentLight, .translucent, .frosted, .solid: return inherited
        }
    }

    /// Synthetic document art for the layout preview; no desktop content is captured.
    static func previewThumbnail(index: Int) -> NSImage {
        NSImage(size: NSSize(width: 320, height: 200), flipped: true) { bounds in
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(rect: bounds).fill()
            let accents: [NSColor] = [.systemBlue, .systemPurple, .systemTeal]
            accents[index % accents.count].withAlphaComponent(0.15).setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: 70, height: 200)).fill()
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            for row in 0..<7 {
                let width = CGFloat(110 + (row * 29 + index * 17) % 100)
                NSBezierPath(roundedRect: CGRect(x: 86, y: CGFloat(23 + row * 23), width: width, height: 7), xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
    }

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

/// A local environment override, not a preferredColorScheme/window-wide preference:
/// rendering a dark preview must not also turn its surrounding Preferences UI dark.
private struct PanelAppearanceModifier: ViewModifier {
    let material: Preferences.PanelMaterial
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, Theme.panelColorScheme(material: material, inherited: inherited))
    }
}

extension View {
    func swiitchPanelAppearance(material: Preferences.PanelMaterial) -> some View {
        modifier(PanelAppearanceModifier(material: material))
    }
}
