import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            SwitcherTab()
                .tabItem { Label("Switcher", systemImage: "rectangle.stack") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(Preferences.Key.launchAtLogin) private var launchAtLogin: Bool = false
    @AppStorage(Preferences.Key.showMenuBarIcon) private var showMenuBarIcon: Bool = true
    @AppStorage(Preferences.Key.showDockIcon) private var showDockIcon: Bool = false
    @AppStorage(Preferences.Key.currentAppHotkeyEnabled) private var currentAppHotkeyEnabled: Bool = false
    @StateObject private var permissions = PermissionsMonitor()

    var body: some View {
        Form {
            // Only surface Permissions when something actually needs attention.
            // When both are granted there's nothing actionable to show; the row
            // dominated the top of the tab and added visual noise.
            if !permissions.accessibilityGranted || !permissions.screenCaptureGranted {
                Section("Permissions") {
                    if !permissions.accessibilityGranted {
                        PermissionRow(
                            title: "Accessibility",
                            granted: false,
                            action: permissions.requestAccessibility
                        )
                    }
                    if !permissions.screenCaptureGranted {
                        PermissionRow(
                            title: "Screen Recording",
                            granted: false,
                            action: permissions.requestScreenCapture
                        )
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section {
                HStack {
                    Text("All windows")
                    Spacer()
                    ShortcutRecorder(
                        keyCodeKey: Preferences.Key.hotkeyKeyCode,
                        modifierFlagsKey: Preferences.Key.hotkeyModifierFlags,
                        defaultKeyCode: 48, // Tab
                        defaultModifiers: .maskCommand
                    )
                }
                HStack {
                    Toggle("Current app's windows", isOn: $currentAppHotkeyEnabled)
                    Spacer()
                    ShortcutRecorder(
                        keyCodeKey: Preferences.Key.currentAppHotkeyKeyCode,
                        modifierFlagsKey: Preferences.Key.currentAppHotkeyModifierFlags,
                        defaultKeyCode: 48, // Tab
                        defaultModifiers: .maskAlternate
                    )
                    .disabled(!currentAppHotkeyEnabled)
                }
                Text("Click a recorder, press your shortcut. Esc cancels. The second hotkey jumps straight to the frontmost app's windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hotkeys")
            }

            Section {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle("Show Dock icon", isOn: $showDockIcon)
            } header: {
                Text("Visibility")
            } footer: {
                if !showMenuBarIcon && !showDockIcon {
                    Text("With both icons hidden, open Swiitch from Finder or Spotlight to reach preferences.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.start() }
        .onDisappear { permissions.stop() }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Open Settings…", action: action)
            }
        }
    }
}

// MARK: - Switcher

private struct SwitcherTab: View {
    @AppStorage(Preferences.Key.displayMode) private var displayMode: String = Preferences.DisplayMode.apps.rawValue
    @AppStorage(Preferences.Key.showWindowPreviews) private var showWindowPreviews: Bool = true
    @AppStorage(Preferences.Key.includeOtherSpaces) private var includeOtherSpaces: Bool = true
    @AppStorage(Preferences.Key.restrictToActiveScreen) private var restrictToActiveScreen: Bool = true
    @AppStorage(Preferences.Key.screenScope) private var screenScope: String = Preferences.ScreenScope.mousePointer.rawValue
    @AppStorage(Preferences.Key.switcherShowDelayMs) private var switcherShowDelayMs: Int = 150
    @AppStorage(Preferences.Key.maxPanelWidthPercent) private var maxPanelWidthPercent: Int = 60
    @AppStorage(Preferences.Key.shiftCyclesBackwards) private var shiftCyclesBackwards: Bool = true
    @AppStorage(Preferences.Key.peekOnHover) private var peekOnHover: Bool = false
    @AppStorage(Preferences.Key.peekDelayMs) private var peekDelayMs: Int = 500

    var body: some View {
        Form {
            Section("Display") {
                Picker("Show", selection: $displayMode) {
                    ForEach(Preferences.DisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                // Only relevant when Apps mode is active — hide entirely when "All windows"
                // is selected so it doesn't look like a stranded disabled control.
                if displayMode == Preferences.DisplayMode.apps.rawValue {
                    Toggle("Show window list for apps with multiple windows", isOn: $showWindowPreviews)
                }
            }

            Section("Scope") {
                Picker("Show on screen", selection: $screenScope) {
                    ForEach(Preferences.ScreenScope.allCases) { scope in
                        Text(scope.label).tag(scope.rawValue)
                    }
                }
                Toggle("Only show windows on that screen", isOn: $restrictToActiveScreen)
                Toggle("Include windows from other Spaces", isOn: $includeOtherSpaces)
            }

            Section("Navigation") {
                Toggle("Shift cycles backward (without Tab)", isOn: $shiftCyclesBackwards)
                Text("When on, pressing Shift while ⌘ is held cycles to the previous app/window. Same effect as ⌘+⇧+Tab, fewer keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Peek") {
                Toggle("Peek window on hover", isOn: $peekOnHover)
                if peekOnHover {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Peek after")
                            Spacer()
                            Text("\(peekDelayMs) ms")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(peekDelayMs) },
                                set: { peekDelayMs = Int($0.rounded()) }
                            ),
                            in: 50...2500, step: 50
                        )
                    }
                    .padding(.vertical, 4)
                }
                Text("Hovering — or navigating with the keyboard — to a cell will bring that window forward without dismissing the picker. Release ⌘ commits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Show after")
                        Spacer()
                        Text("\(switcherShowDelayMs) ms")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(switcherShowDelayMs) },
                            set: { switcherShowDelayMs = Int($0.rounded()) }
                        ),
                        in: 0...500, step: 25
                    )
                    Text("Release ⌘ before this delay to switch without showing the panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Layout") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Wrap past")
                        Spacer()
                        Text("\(maxPanelWidthPercent)% of screen")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(maxPanelWidthPercent) },
                            set: { maxPanelWidthPercent = Int($0.rounded()) }
                        ),
                        in: 30...100, step: 5
                    )
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @AppStorage(Preferences.Key.appearance) private var appearance: String = Preferences.Appearance.system.rawValue
    @AppStorage(Preferences.Key.accentColorHex) private var accentColorHex: String = ""
    @AppStorage(Preferences.Key.thumbnailSize) private var thumbnailSize: String = Preferences.ThumbnailSize.medium.rawValue
    @AppStorage(Preferences.Key.panelMaterial) private var panelMaterial: String = Preferences.PanelMaterial.translucentLight.rawValue
    @AppStorage(Preferences.Key.panelCornerRadius) private var panelCornerRadius: Int = 16
    @AppStorage(Preferences.Key.overlayPosition) private var overlayPosition: String = Preferences.OverlayPosition.bottomLeading.rawValue
    @AppStorage(Preferences.Key.thumbnailOverlay) private var thumbnailOverlay: String = Preferences.ThumbnailOverlay.none.rawValue
    @AppStorage(Preferences.Key.themePreset) private var themePreset: String = Preferences.ThemePreset.classic.rawValue
    @AppStorage(Preferences.Key.displayMode) private var displayMode: String = Preferences.DisplayMode.windows.rawValue

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: accentColorHex) ?? .accentColor },
            set: { accentColorHex = $0.hexString }
        )
    }

    private var currentMaterialBlurb: String {
        Preferences.PanelMaterial(rawValue: panelMaterial)?.blurb ?? ""
    }

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $themePreset) {
                    ForEach(Preferences.ThemePreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
                .onChange(of: themePreset) { _, newValue in
                    if let preset = Preferences.ThemePreset(rawValue: newValue), preset != .custom {
                        preset.apply()
                    }
                }
                Text("Presets bulk-apply background, radius, thumbnail size, overlay, and accent. Tweaking any value below switches to Custom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SwitcherPreviewCard(
                    isWindowsMode: displayMode == Preferences.DisplayMode.windows.rawValue,
                    panelMaterial: Preferences.PanelMaterial(rawValue: panelMaterial) ?? .translucentLight,
                    cornerRadius: CGFloat(panelCornerRadius),
                    overlayPosition: Preferences.OverlayPosition(rawValue: overlayPosition) ?? .bottomLeading,
                    thumbnailOverlay: Preferences.ThumbnailOverlay(rawValue: thumbnailOverlay) ?? .none,
                    accent: Color(hex: accentColorHex) ?? .accentColor
                )
                .padding(.vertical, 4)
            } header: {
                Text("Theme")
            }

            Section("System") {
                Picker("System appearance", selection: $appearance) {
                    ForEach(Preferences.Appearance.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                HStack {
                    ColorPicker("Accent color", selection: accentColorBinding, supportsOpacity: false)
                        .onChange(of: accentColorHex) { _, _ in markCustom() }
                    if !accentColorHex.isEmpty {
                        Button("Reset") {
                            accentColorHex = ""
                            markCustom()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section {
                Picker("Background", selection: $panelMaterial) {
                    ForEach(Preferences.PanelMaterial.allCases) { mat in
                        Text(mat.label).tag(mat.rawValue)
                    }
                }
                .onChange(of: panelMaterial) { _, _ in markCustom() }
                Text(currentMaterialBlurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Corner radius")
                        Spacer()
                        Text("\(panelCornerRadius) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(panelCornerRadius) },
                            set: { panelCornerRadius = Int($0.rounded()); markCustom() }
                        ),
                        in: 0...28, step: 1
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text("Switcher panel")
            }

            Section("Window cells") {
                Picker("Thumbnail size", selection: $thumbnailSize) {
                    ForEach(Preferences.ThumbnailSize.allCases) { size in
                        Text(size.label).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: thumbnailSize) { _, _ in markCustom() }

                Picker("App icon overlay", selection: $overlayPosition) {
                    ForEach(Preferences.OverlayPosition.allCases) { pos in
                        Text(pos.label).tag(pos.rawValue)
                    }
                }
                .onChange(of: overlayPosition) { _, _ in markCustom() }

                Picker("Thumbnail effect", selection: $thumbnailOverlay) {
                    ForEach(Preferences.ThumbnailOverlay.allCases) { overlay in
                        Text(overlay.label).tag(overlay.rawValue)
                    }
                }
                .onChange(of: thumbnailOverlay) { _, _ in markCustom() }
            }
        }
        .formStyle(.grouped)
    }

    /// Any individual tweak flips the preset picker to Custom so the user knows their
    /// preset selection no longer matches the current state.
    private func markCustom() {
        if themePreset != Preferences.ThemePreset.custom.rawValue {
            themePreset = Preferences.ThemePreset.custom.rawValue
        }
    }
}

// MARK: - Switcher preview card (live preview in Appearance tab)

private struct SwitcherPreviewCard: View {
    let isWindowsMode: Bool
    let panelMaterial: Preferences.PanelMaterial
    let cornerRadius: CGFloat
    let overlayPosition: Preferences.OverlayPosition
    let thumbnailOverlay: Preferences.ThumbnailOverlay
    let accent: Color

    private static let windowTitles   = ["main.swift — MyApp", "README.md — Editor", "GitHub — Safari"]
    private static let windowAppNames = ["Xcode", "VS Code", "Safari"]
    private static let windowColors: [Color] = [.blue.opacity(0.2), .indigo.opacity(0.2), .teal.opacity(0.2)]

    private static let appNames:  [String] = ["Safari", "Xcode", "Finder", "Notes", "Mail"]
    private static let appColors: [Color]  = [.blue, .orange, .green, .purple, .red]

    var body: some View {
        HStack(spacing: 10) {
            if isWindowsMode {
                ForEach(0..<3, id: \.self) { i in
                    previewWindowCell(index: i)
                }
            } else {
                ForEach(0..<5, id: \.self) { i in
                    previewAppCell(index: i)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.panelBackground(material: panelMaterial, cornerRadius: cornerRadius))
        .environment(\.swiitchAccent, accent)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func previewWindowCell(index: Int) -> some View {
        let isSelected = index == 0
        let bgColor = Self.windowColors[index]
        VStack(spacing: 4) {
            ZStack(alignment: overlayPosition == .hidden ? .center : overlayPosition.swiftAlignment) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.15) : Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isSelected ? accent : Color.primary.opacity(0.1),
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
                // Fake thumbnail
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(bgColor)
                    .padding(4)
                    .overlay(previewThumbnailOverlay)
                // App icon badge
                if overlayPosition != .hidden {
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 14, height: 14)
                        .padding(5)
                }
            }
            .frame(height: 64)
            VStack(spacing: 1) {
                Text(Self.windowTitles[index])
                    .font(.system(size: 8.5))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                Text(Self.windowAppNames[index])
                    .font(.system(size: 7.5))
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func previewAppCell(index: Int) -> some View {
        let isSelected = index == 0
        let color = Self.appColors[index]
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.35) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5)
                    )
                    .frame(width: 48, height: 48)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color)
                    .frame(width: 32, height: 32)
            }
            Text(Self.appNames[index])
                .font(.system(size: 8.5))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var previewThumbnailOverlay: some View {
        switch thumbnailOverlay {
        case .none:
            EmptyView()
        case .gradientEdges:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: accent.opacity(0.55), location: 0.0),
                            .init(color: accent.opacity(0.0),  location: 0.25),
                            .init(color: accent.opacity(0.0),  location: 0.75),
                            .init(color: accent.opacity(0.55), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
        case .scanlines:
            Canvas { ctx, size in
                let path = Path { p in
                    var y: CGFloat = 0
                    while y < size.height {
                        p.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                        y += 3
                    }
                }
                ctx.fill(path, with: .color(.black.opacity(0.25)))
            }
        case .tint:
            accent.opacity(0.22)
                .blendMode(.multiply)
        }
    }
}


private struct AboutTab: View {
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 64, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text("Swiitch")
                .font(.title.weight(.semibold))
            Text(versionText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                .padding(.top, 10)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
