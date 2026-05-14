import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Preferences are stored in `UserDefaults.standard` and surfaced to SwiftUI via `@AppStorage`
/// using the keys below. Keeping this as a plain namespace (rather than an `ObservableObject`)
/// avoids a SwiftUI footgun: `MenuBarExtra(isInserted:)` writes back to its binding during
/// scene updates, and routing that write through a `@Published` property logs
/// "Publishing changes from within view updates is not allowed".
enum Preferences {
    enum Key {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let showWindowPreviews = "showWindowPreviews"
        static let includeOtherSpaces = "includeOtherSpaces"
        static let launchAtLogin = "launchAtLogin"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockIcon = "showDockIcon"
        static let switcherShowDelayMs = "switcherShowDelayMs"
        static let displayMode = "displayMode"               // "apps" or "windows"
        static let maxPanelWidthPercent = "maxPanelWidthPercent"  // Int, % of active screen width
        static let restrictToActiveScreen = "restrictToActiveScreen"  // Bool
        static let appearance = "appearance"                 // "system" | "light" | "dark"
        static let accentColorHex = "accentColorHex"          // "#RRGGBB" or ""
        static let thumbnailSize = "thumbnailSize"            // "small" | "medium" | "large"
        static let panelMaterial = "panelMaterial"            // see PanelMaterial enum
        static let panelCornerRadius = "panelCornerRadius"    // Int, 0-24
        static let overlayPosition = "overlayPosition"        // OverlayPosition.rawValue
        static let themePreset = "themePreset"                // ThemePreset.rawValue
        static let thumbnailOverlay = "thumbnailOverlay"      // ThumbnailOverlay.rawValue
        static let shiftCyclesBackwards = "shiftCyclesBackwards"  // Bool
        static let pinnedBundleIDs = "pinnedBundleIDs"            // [String]
        static let hotkeyKeyCode = "hotkeyKeyCode"                // Int (kVK_Tab default = 48)
        static let hotkeyModifierFlags = "hotkeyModifierFlags"    // Int — raw CGEventFlags value
        static let peekOnHover = "peekOnHover"                    // Bool
        static let peekDelayMs = "peekDelayMs"                    // Int (default 500)
        static let screenScope = "screenScope"                    // ScreenScope.rawValue

        // Second hotkey — opens the picker directly in "current app's windows" mode.
        static let currentAppHotkeyEnabled = "currentAppHotkeyEnabled"     // Bool
        static let currentAppHotkeyKeyCode = "currentAppHotkeyKeyCode"     // Int
        static let currentAppHotkeyModifierFlags = "currentAppHotkeyModifierFlags" // Int
    }

    enum ScreenScope: String, CaseIterable, Identifiable {
        case mousePointer  // the screen containing the mouse cursor — Swiitch's previous default
        case activeWindow  // the screen of the frontmost app's key window
        case main          // NSScreen.main — the primary display
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mousePointer: return "Screen with mouse pointer"
            case .activeWindow: return "Active screen (frontmost window)"
            case .main:         return "Main screen"
            }
        }
    }

    // MARK: - Pinned apps

    static var pinnedBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Key.pinnedBundleIDs) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Key.pinnedBundleIDs) }
    }

    static func togglePinned(_ bundleID: String) {
        var current = pinnedBundleIDs
        if let idx = current.firstIndex(of: bundleID) {
            current.remove(at: idx)
        } else {
            current.append(bundleID)
        }
        pinnedBundleIDs = current
    }

    static func isPinned(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return pinnedBundleIDs.contains(bundleID)
    }

    enum DisplayMode: String, CaseIterable, Identifiable {
        case apps
        case windows
        var id: String { rawValue }
        var label: String {
            switch self {
            case .apps: return "Apps (drill into windows with ↓)"
            case .windows: return "All windows directly"
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "Follow system"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    enum ThumbnailSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }
        var label: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
        var thumbHeight: CGFloat {
            switch self {
            case .small: return 90
            case .medium: return 130
            case .large: return 180
            }
        }
        var cellWidth: CGFloat {
            switch self {
            case .small: return 160
            case .medium: return 210
            case .large: return 260
            }
        }
    }

    enum PanelMaterial: String, CaseIterable, Identifiable {
        case translucentLight  // ultraThin material — most see-through
        case translucent       // regular material — middle ground
        case frosted           // thick material — heavily blurred
        case solidLight        // opaque light grey
        case solidDark         // opaque near-black
        var id: String { rawValue }
        var label: String {
            switch self {
            case .translucentLight: return "Translucent (light)"
            case .translucent:      return "Translucent"
            case .frosted:          return "Frosted"
            case .solidLight:       return "Solid Light"
            case .solidDark:        return "Solid Dark"
            }
        }
        var blurb: String {
            switch self {
            case .translucentLight: return "Most see-through. Lets the desktop / app behind show clearly."
            case .translucent:      return "Default macOS blur. Balanced."
            case .frosted:          return "Heavily blurred — barely shows what's behind."
            case .solidLight:       return "Opaque light grey. No translucency."
            case .solidDark:        return "Opaque near-black. No translucency."
            }
        }
    }

    enum OverlayPosition: String, CaseIterable, Identifiable {
        case hidden, topLeading, topTrailing, bottomLeading, bottomTrailing, center
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hidden:         return "Hidden"
            case .topLeading:     return "Top Left"
            case .topTrailing:    return "Top Right"
            case .bottomLeading:  return "Bottom Left"
            case .bottomTrailing: return "Bottom Right"
            case .center:         return "Center"
            }
        }
        var swiftAlignment: Alignment {
            switch self {
            case .hidden:         return .center // unused
            case .topLeading:     return .topLeading
            case .topTrailing:    return .topTrailing
            case .bottomLeading:  return .bottomLeading
            case .bottomTrailing: return .bottomTrailing
            case .center:         return .center
            }
        }
    }

    /// Accent-driven decorations applied on top of each window thumbnail.
    enum ThumbnailOverlay: String, CaseIterable, Identifiable {
        case none           // no overlay
        case gradientEdges  // subtle accent-colored gradients on the top + bottom edges
        case scanlines      // CRT-style horizontal scanline overlay
        case tint           // light accent multiply across the whole thumbnail
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none:           return "None"
            case .gradientEdges:  return "Gradient edges"
            case .scanlines:      return "Scanlines"
            case .tint:           return "Color tint"
            }
        }
    }

    /// Named theme bundles that bulk-apply several appearance prefs at once.
    enum ThemePreset: String, CaseIterable, Identifiable {
        case custom    // sentinel — applied when user has tweaked any value individually
        case classic   // current defaults
        case minimal   // small, clean, no overlay
        case raycast   // dark, sharper, prominent
        case frosted   // very translucent, large thumbs
        case spotlight // light, sober
        case synthwave // wild — solid dark + magenta + gradient-edged thumbnails

        var id: String { rawValue }
        var label: String {
            switch self {
            case .custom:    return "Custom"
            case .classic:   return "Classic"
            case .minimal:   return "Minimal"
            case .raycast:   return "Raycast-style"
            case .frosted:   return "Frosted"
            case .spotlight: return "Spotlight-style"
            case .synthwave: return "Synthwave"
            }
        }

        /// Write the preset's values into UserDefaults. The picker is just a convenience —
        /// the actual source of truth is still the individual keys.
        func apply() {
            let d = UserDefaults.standard
            switch self {
            case .custom:
                return // no-op — represents "I've been tweaking it"

            case .classic:
                d.set(PanelMaterial.translucentLight.rawValue, forKey: Key.panelMaterial)
                d.set(16, forKey: Key.panelCornerRadius)
                d.set(ThumbnailSize.medium.rawValue, forKey: Key.thumbnailSize)
                d.set(OverlayPosition.bottomLeading.rawValue, forKey: Key.overlayPosition)
                d.set("", forKey: Key.accentColorHex)
                d.set(ThumbnailOverlay.none.rawValue, forKey: Key.thumbnailOverlay)

            case .minimal:
                d.set(PanelMaterial.solidLight.rawValue, forKey: Key.panelMaterial)
                d.set(6, forKey: Key.panelCornerRadius)
                d.set(ThumbnailSize.small.rawValue, forKey: Key.thumbnailSize)
                d.set(OverlayPosition.hidden.rawValue, forKey: Key.overlayPosition)
                d.set("", forKey: Key.accentColorHex)
                d.set(ThumbnailOverlay.none.rawValue, forKey: Key.thumbnailOverlay)

            case .raycast:
                d.set(PanelMaterial.solidDark.rawValue, forKey: Key.panelMaterial)
                d.set(14, forKey: Key.panelCornerRadius)
                d.set(ThumbnailSize.medium.rawValue, forKey: Key.thumbnailSize)
                d.set(OverlayPosition.topLeading.rawValue, forKey: Key.overlayPosition)
                d.set("#FF5C5C", forKey: Key.accentColorHex)
                d.set(ThumbnailOverlay.none.rawValue, forKey: Key.thumbnailOverlay)

            case .frosted:
                d.set(PanelMaterial.frosted.rawValue, forKey: Key.panelMaterial)
                d.set(24, forKey: Key.panelCornerRadius)
                d.set(ThumbnailSize.large.rawValue, forKey: Key.thumbnailSize)
                d.set(OverlayPosition.bottomLeading.rawValue, forKey: Key.overlayPosition)
                d.set("", forKey: Key.accentColorHex)
                d.set(ThumbnailOverlay.none.rawValue, forKey: Key.thumbnailOverlay)

            case .spotlight:
                d.set(PanelMaterial.solidLight.rawValue, forKey: Key.panelMaterial)
                d.set(18, forKey: Key.panelCornerRadius)
                d.set(ThumbnailSize.medium.rawValue, forKey: Key.thumbnailSize)
                d.set(OverlayPosition.bottomLeading.rawValue, forKey: Key.overlayPosition)
                d.set("", forKey: Key.accentColorHex)
                d.set(ThumbnailOverlay.none.rawValue, forKey: Key.thumbnailOverlay)

            case .synthwave:
                d.set(PanelMaterial.solidDark.rawValue, forKey: Key.panelMaterial)
                d.set(20, forKey: Key.panelCornerRadius)
                d.set(ThumbnailSize.large.rawValue, forKey: Key.thumbnailSize)
                d.set(OverlayPosition.bottomLeading.rawValue, forKey: Key.overlayPosition)
                d.set("#FF2D95", forKey: Key.accentColorHex)
                d.set(ThumbnailOverlay.gradientEdges.rawValue, forKey: Key.thumbnailOverlay)
            }
        }
    }

    /// Registered defaults (the value `UserDefaults.bool(forKey:)` returns when the user hasn't
    /// set anything yet). Call once at launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.showWindowPreviews: true,
            Key.includeOtherSpaces: true,
            Key.showMenuBarIcon: true,
            Key.showDockIcon: false,
            Key.switcherShowDelayMs: 150,
            Key.displayMode: DisplayMode.apps.rawValue,
            Key.maxPanelWidthPercent: 60,
            Key.restrictToActiveScreen: true,
            Key.appearance: Appearance.system.rawValue,
            Key.accentColorHex: "",
            Key.thumbnailSize: ThumbnailSize.medium.rawValue,
            Key.panelMaterial: PanelMaterial.translucentLight.rawValue,
            Key.panelCornerRadius: 16,
            Key.overlayPosition: OverlayPosition.bottomLeading.rawValue,
            Key.thumbnailOverlay: ThumbnailOverlay.none.rawValue,
            Key.themePreset: ThemePreset.classic.rawValue,
            Key.shiftCyclesBackwards: true,
            // kVK_Tab = 48; CGEventFlags.maskCommand.rawValue = 0x100000 (1048576)
            Key.hotkeyKeyCode: 48,
            Key.hotkeyModifierFlags: Int(CGEventFlags.maskCommand.rawValue),
            Key.peekOnHover: false,
            Key.peekDelayMs: 500,
            Key.screenScope: ScreenScope.mousePointer.rawValue,
            Key.currentAppHotkeyEnabled: false,
            // Defaults to ⌥+Tab (kVK_Tab = 48, Option = 0x80000)
            Key.currentAppHotkeyKeyCode: 48,
            Key.currentAppHotkeyModifierFlags: Int(CGEventFlags.maskAlternate.rawValue)
        ])
    }

    static func applyAppearance() {
        let raw = UserDefaults.standard.string(forKey: Key.appearance) ?? Appearance.system.rawValue
        switch Appearance(rawValue: raw) ?? .system {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Side-effecting actions

    /// Brings `SMAppService.mainApp` into sync with the stored `launchAtLogin` flag.
    static func syncLaunchAtLogin() {
        let desired = UserDefaults.standard.bool(forKey: Key.launchAtLogin)
        do {
            let isEnabled = SMAppService.mainApp.status == .enabled
            if desired && !isEnabled {
                try SMAppService.mainApp.register()
            } else if !desired && isEnabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[Swiitch] Failed to update Launch at Login: \(error)")
        }
    }

    /// Reads the actual SMAppService status — the truth might diverge from the stored
    /// preference if the user toggled the login item via System Settings.
    static var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
