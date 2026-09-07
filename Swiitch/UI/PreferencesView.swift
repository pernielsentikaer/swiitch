import SwiftUI
import UniformTypeIdentifiers

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case switcher
    case appearance
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .switcher: String(localized: "Switcher")
        case .appearance: String(localized: "Appearance")
        case .about: String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .switcher: "rectangle.stack"
        case .appearance: "paintpalette"
        case .about: "info.circle"
        }
    }
}

struct PreferencesView: View {
    @State private var selection: PreferencesSection = .general

    init(initialSelection: PreferencesSection = .general) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView {
            List(PreferencesSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: 720,
            idealWidth: 780,
            maxWidth: .infinity,
            minHeight: 520,
            idealHeight: 600,
            maxHeight: .infinity
        )
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            GeneralTab()
        case .switcher:
            SwitcherTab()
        case .appearance:
            AppearanceTab()
        case .about:
            AboutTab()
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(Preferences.Key.showMenuBarIcon) private var showMenuBarIcon: Bool = true
    @AppStorage(Preferences.Key.showDockIcon) private var showDockIcon: Bool = false
    @AppStorage(Preferences.Key.currentAppHotkeyEnabled) private var currentAppHotkeyEnabled: Bool = false
    @AppStorage(Preferences.Key.hotkeyKeyCode) private var hotkeyKeyCode: Int = 48
    @AppStorage(Preferences.Key.hotkeyModifierFlags) private var hotkeyModifierFlags: Int = Int(CGEventFlags.maskCommand.rawValue)
    @AppStorage(Preferences.Key.currentAppHotkeyKeyCode) private var currentAppHotkeyKeyCode: Int = 48
    @AppStorage(Preferences.Key.currentAppHotkeyModifierFlags) private var currentAppHotkeyModifierFlags: Int = Int(CGEventFlags.maskAlternate.rawValue)
    @StateObject private var permissions = PermissionsMonitor()
    @ObservedObject private var hotkeyStatus = HotkeyStatus.shared
    @ObservedObject private var updates = UpdateController.shared
    @State private var showResetConfirmation = false

    private var hotkeysConflict: Bool {
        currentAppHotkeyEnabled && Shortcut.conflicts(
            (hotkeyKeyCode, CGEventFlags(rawValue: UInt64(hotkeyModifierFlags))),
            (currentAppHotkeyKeyCode, CGEventFlags(rawValue: UInt64(currentAppHotkeyModifierFlags)))
        )
    }

    var body: some View {
        Form {
            // Only surface Permissions when something actually needs attention.
            // When both are granted there's nothing actionable to show; the row
            // dominated the top of the tab and added visual noise.
            if !permissions.accessibilityGranted || !permissions.screenCaptureGranted {
                Section("Permissions") {
                    if !permissions.accessibilityGranted {
                        PermissionRow(
                            title: String(localized: "Accessibility"),
                            subtitle: String(localized: "Required to list, raise, and switch between windows in other apps."),
                            granted: false,
                            action: permissions.requestAccessibility
                        )
                    }
                    if !permissions.screenCaptureGranted {
                        PermissionRow(
                            title: String(localized: "Screen Recording"),
                            subtitle: String(localized: "Optional. Enables live window thumbnails in the switcher."),
                            granted: false,
                            action: permissions.requestScreenCapture
                        )
                    }
                }
            }

            Section("Startup") {
                LoginItemSetting(title: String(localized: "Launch at login"))
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
                if hotkeyStatus.value == .retrying {
                    Label("Keyboard shortcut temporarily unavailable. Swiitch is retrying automatically.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if hotkeysConflict {
                    Label("These shortcuts overlap, including Shift-reverse. Choose different combinations.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                }
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

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticChecksEnabled },
                    set: { updates.setAutomaticChecksEnabled($0) }
                ))
                if let error = updates.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                #if DEBUG
                Text("Development builds check only when you choose Check for Updates.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }

            Section {
                Button("Reset All Settings to Defaults…", role: .destructive) {
                    showResetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, -10, for: .scrollContent)
        .onAppear { permissions.start() }
        .onDisappear { permissions.stop() }
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Preferences.resetSettings()
                Preferences.applyAppearance()
                Preferences.syncLaunchAtLogin()
            }
        } message: {
            Text("Hotkeys, appearance, pinned apps, and excluded apps will all be reset. Onboarding will remain completed.")
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    @AppStorage(Preferences.Key.includeOtherSpaces) private var includeOtherSpaces: Bool = true
    @AppStorage(Preferences.Key.includeMinimizedWindows) private var includeMinimizedWindows: Bool = true
    @AppStorage(Preferences.Key.restrictToActiveScreen) private var restrictToActiveScreen: Bool = true
    @AppStorage(Preferences.Key.screenScope) private var screenScope: String = Preferences.ScreenScope.mousePointer.rawValue
    @AppStorage(Preferences.Key.switcherShowDelayMs) private var switcherShowDelayMs: Int = 150
    @AppStorage(Preferences.Key.maxPanelWidthPercent) private var maxPanelWidthPercent: Int = 60
    @AppStorage(Preferences.Key.shiftCyclesBackwards) private var shiftCyclesBackwards: Bool = true
    @AppStorage(Preferences.Key.peekOnHover) private var peekOnHover: Bool = false
    @AppStorage(Preferences.Key.peekDelayMs) private var peekDelayMs: Int = 500
    @AppStorage(Preferences.Key.showWindowControlsOnHover) private var showWindowControlsOnHover: Bool = false
    @AppStorage(Preferences.Key.fitWindowGridToScreen) private var fitWindowGridToScreen: Bool = false

    var body: some View {
        Form {
            Section("Display") {
                ForEach(Preferences.DisplayMode.allCases) { mode in
                    displayModeButton(for: mode)
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
                Toggle("Include minimized windows", isOn: $includeMinimizedWindows)
                Text("Minimized windows can be included even when other Spaces are hidden. The screen filter still applies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ExcludedAppsEditor()

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

            Section("Window actions") {
                Toggle("Show window controls on hover", isOn: $showWindowControlsOnHover)
                Text("Shows close, minimize, and native zoom controls on the window under the pointer. Unavailable controls are dimmed. With the default shortcut, use ⌃⌘H to hide the selected app.")
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
                        Text("Maximum width")
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

                Picker("Window grid", selection: $fitWindowGridToScreen) {
                    Text("Automatic").tag(false)
                    Text("Fill Screen").tag(true)
                }
                .pickerStyle(.segmented)
                if displayMode == Preferences.DisplayMode.apps.rawValue {
                    Text("Applies when viewing an app’s windows.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    fitWindowGridToScreen
                        ? String(localized: "Resizes tiles to use this width while keeping every window visible on the active display.")
                        : String(localized: "Uses your selected thumbnail size and wraps windows into additional rows.")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SwitcherPreview(showsWindowGrid: true)
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, -10, for: .scrollContent)
    }

    private func displayModeButton(for mode: Preferences.DisplayMode) -> some View {
        let isSelected = displayMode == mode.rawValue

        return Button {
            displayMode = mode.rawValue
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ExcludedAppsEditor: View {
    private struct ExcludedApp: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    @State private var excludedApps: [ExcludedApp] = []

    var body: some View {
        Section {
            if excludedApps.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("All apps are included")
                        Text("Add an app to hide all of its windows from Swiitch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    addAppButton
                }
                .padding(.vertical, 6)
            } else {
                ForEach(excludedApps) { app in
                    HStack(spacing: 12) {
                        Group {
                            if let icon = app.icon {
                                Image(nsImage: icon)
                                    .resizable()
                            } else {
                                Image(systemName: "app.dashed")
                                    .resizable()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .scaledToFit()
                        .frame(width: 32, height: 32)

                        Text(app.name)
                        Spacer()
                        Button {
                            Preferences.includeApp(app.id)
                            reload()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Include \(app.name) again")
                        .help("Include this app again")
                    }
                    .help(app.id)
                }

                HStack {
                    addAppButton
                    Spacer()
                    Text(excludedApps.count == 1 ? String(localized: "1 app excluded") : String(localized: "\(excludedApps.count) apps excluded"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Excluded apps")
        } footer: {
            Text("You can also right-click an app in Swiitch and choose Exclude from Swiitch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reload()
        }
    }

    private var addAppButton: some View {
        Button {
            pickApps()
        } label: {
            Label("Add App…", systemImage: "plus")
        }
    }

    private func reload() {
        excludedApps = Preferences.excludedBundleIDs
            .map(appDetails(for:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Apps to Exclude")
        panel.prompt = String(localized: "Exclude")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            Preferences.excludeApp(bundleID)
        }
        reload()
    }

    private func appDetails(for bundleID: String) -> ExcludedApp {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return ExcludedApp(id: bundleID, name: bundleID, icon: nil)
        }
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return ExcludedApp(id: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
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
    @State private var applyingPreset = false

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
                        applyingPreset = true
                        preset.apply()
                        // @AppStorage propagates the individual preset writes on the next
                        // run-loop turns. Keep their markCustom callbacks suppressed until then.
                        DispatchQueue.main.async {
                            DispatchQueue.main.async {
                                applyingPreset = false
                            }
                        }
                    }
                }
                Text("Presets bulk-apply background, radius, thumbnail size, overlay, and accent. Tweaking any value below switches to Custom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SwitcherPreview()
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
        .contentMargins(.top, -10, for: .scrollContent)
    }

    /// Any individual tweak flips the preset picker to Custom so the user knows their
    /// preset selection no longer matches the current state.
    private func markCustom() {
        guard !applyingPreset else { return }
        if themePreset != Preferences.ThemePreset.custom.rawValue {
            themePreset = Preferences.ThemePreset.custom.rawValue
        }
    }
}



private struct AboutTab: View {
    @State private var showDiagnostics = false
    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(version) (\(build))")
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
            Button("Review Diagnostics…") { showDiagnostics = true }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
    }
}
