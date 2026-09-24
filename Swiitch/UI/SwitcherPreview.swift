import AppKit
import SwiftUI

/// Scaled sample layout using the same width limits, grid metrics and cells as the picker.
/// It never enumerates real windows or requests Screen Recording permission.
struct SwitcherPreviewLayout {
    let screenSize: CGSize
    let count: Int
    let isWindowsMode: Bool
    let maximumPanelWidth: CGFloat
    let metrics: SwitcherLayout.GridMetrics
    let rows: Int
    let panelWidth: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    var needsScrolling: Bool { contentHeight > viewportHeight }

    init(
        screenSize: CGSize, count: Int, isWindowsMode: Bool,
        thumbnailSize: Preferences.ThumbnailSize, maximumWidthPercent: Int, fitAll: Bool
    ) {
        let screen = CGSize(width: max(400, screenSize.width), height: max(300, screenSize.height))
        self.screenSize = screen
        self.count = max(1, min(count, 80))
        self.isWindowsMode = isWindowsMode
        let limits = SwitcherPanelSizing.limits(screenWidth: screen.width, percent: maximumWidthPercent)
        maximumPanelWidth = limits.panel
        let maximumHeight = SwitcherPanelSizing.panelHeight(fittingHeight: screen.height, screenHeight: screen.height)
        metrics = isWindowsMode ? SwitcherLayout.gridMetrics(
            count: self.count, maxWidth: limits.grid, availableHeight: maximumHeight - 170,
            thumbnailSize: thumbnailSize, fitAll: fitAll
        ) : .init(columns: SwitcherLayout.appGridColumns(count: self.count, maxWidth: limits.grid), cellWidth: 110, thumbnailHeight: 92)
        rows = Int(ceil(Double(self.count) / Double(metrics.columns)))
        let spacing: CGFloat = isWindowsMode ? 12 : 14
        let gridWidth = CGFloat(metrics.columns) * metrics.cellWidth + CGFloat(metrics.columns - 1) * spacing
        panelWidth = SwitcherPanelSizing.panelWidth(fittingWidth: gridWidth + SwitcherPanelSizing.horizontalChrome, maximumWidth: limits.panel)
        let cellHeight = isWindowsMode ? metrics.thumbnailHeight + 34 : 114
        contentHeight = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * (isWindowsMode ? 14 : 16) + 40
        viewportHeight = min(contentHeight, max(140, maximumHeight - 80))
    }
}

/// Shared between Switcher > Layout and Appearance. Sample count is not a saved preference.
struct SwitcherPreview: View {
    /// Layout controls always preview the window grid, including when Apps is the
    /// opening mode; otherwise changing Automatic / Fill Screen would appear inert.
    var showsWindowGrid = false
    @AppStorage(Preferences.Key.displayMode) private var displayMode = Preferences.DisplayMode.default.rawValue
    @AppStorage(Preferences.Key.thumbnailSize) private var thumbnailSize = Preferences.ThumbnailSize.medium.rawValue
    @AppStorage(Preferences.Key.maxPanelWidthPercent) private var maximumWidthPercent = 60
    @AppStorage(Preferences.Key.fitWindowGridToScreen) private var fitAll = false
    @AppStorage(Preferences.Key.panelMaterial) private var panelMaterial = Preferences.PanelMaterial.translucentLight.rawValue
    @AppStorage(Preferences.Key.panelCornerRadius) private var cornerRadius = 16
    @AppStorage(Preferences.Key.overlayPosition) private var overlayPosition = Preferences.OverlayPosition.bottomLeading.rawValue
    @AppStorage(Preferences.Key.thumbnailOverlay) private var thumbnailOverlay = Preferences.ThumbnailOverlay.none.rawValue
    @AppStorage(Preferences.Key.accentColorHex) private var accentColorHex = ""
    @State private var sampleCount = 12
    @State private var screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)

    var body: some View {
        let windows = showsWindowGrid || displayMode == Preferences.DisplayMode.windows.rawValue
        let layout = SwitcherPreviewLayout(
            screenSize: screenSize, count: sampleCount, isWindowsMode: windows,
            thumbnailSize: Preferences.ThumbnailSize(rawValue: thumbnailSize) ?? .medium,
            maximumWidthPercent: maximumWidthPercent, fitAll: fitAll
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(windows ? String(localized: "Window layout preview") : String(localized: "App layout preview")).font(.caption.weight(.medium))
                Spacer()
                Picker("Sample count", selection: $sampleCount) {
                    ForEach([6, 12, 24, 40], id: \.self) { count in
                        Text(windows ? String(localized: "\(count) windows") : String(localized: "\(count) apps")).tag(count)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Example items only. Does not change your open windows.")
            }
            SwitcherPreviewCard(
                layout: layout,
                panelMaterial: Preferences.PanelMaterial(rawValue: panelMaterial) ?? .translucentLight,
                cornerRadius: CGFloat(cornerRadius),
                overlayPosition: Preferences.OverlayPosition(rawValue: overlayPosition) ?? .bottomLeading,
                thumbnailOverlay: Preferences.ThumbnailOverlay(rawValue: thumbnailOverlay) ?? .none,
                accent: Color(hex: accentColorHex) ?? .accentColor
            )
            Text("\(layout.metrics.columns) columns × \(layout.rows) rows · \(layout.needsScrolling ? String(localized: "Scrolls for more") : String(localized: "All visible"))")
                .font(.caption).foregroundStyle(.secondary)
            Text("Scaled example on a \(Int(screenSize.width)) × \(Int(screenSize.height)) pt display. Dashed outline shows maximum width.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .onAppear { updateScreenSize() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in updateScreenSize() }
    }

    private func updateScreenSize() {
        if let size = NSScreen.main?.visibleFrame.size { screenSize = size }
    }
}

struct SwitcherPreviewCard: View {
    let layout: SwitcherPreviewLayout
    let panelMaterial: Preferences.PanelMaterial
    let cornerRadius: CGFloat
    let overlayPosition: Preferences.OverlayPosition
    let thumbnailOverlay: Preferences.ThumbnailOverlay
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / layout.screenSize.width
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035))
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: layout.maximumPanelWidth * scale, height: max(20, geometry.size.height - 16))
                samplePanel
                    .scaleEffect(scale)
                    .frame(width: (layout.panelWidth - 40) * scale, height: layout.viewportHeight * scale)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(layout.screenSize.width / layout.screenSize.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var samplePanel: some View {
        let columns = Array(repeating: GridItem(.fixed(layout.metrics.cellWidth), spacing: layout.isWindowsMode ? 12 : 14), count: layout.metrics.columns)
        return ScrollView(.vertical) {
            LazyVGrid(columns: columns, spacing: layout.isWindowsMode ? 14 : 16) {
                ForEach(0..<layout.count, id: \.self) { index in
                    if layout.isWindowsMode {
                        WindowCell(
                            title: String(localized: "\(PreviewSamples.names[index % PreviewSamples.names.count]) — Example \(index + 1)"),
                            thumbnail: PreviewSamples.thumbnails[index % PreviewSamples.thumbnails.count],
                            appIcon: PreviewSamples.icons[index % PreviewSamples.icons.count],
                            overlayPosition: overlayPosition, thumbnailOverlay: thumbnailOverlay,
                            secondaryLabel: PreviewSamples.names[index % PreviewSamples.names.count],
                            isSelected: index == 0, thumbHeight: layout.metrics.thumbnailHeight
                        )
                        .frame(width: layout.metrics.cellWidth)
                    } else {
                        AppCell(app: PreviewSamples.app(index: index), isSelected: index == 0)
                            .frame(width: layout.metrics.cellWidth)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: max(80, layout.panelWidth - 40), height: layout.viewportHeight)
        .background(Theme.panelBackground(material: panelMaterial, cornerRadius: cornerRadius))
        .environment(\.swiitchAccent, accent)
        .swiitchPanelAppearance(material: panelMaterial)
    }
}

private enum PreviewSamples {
    static let names = ["Safari", "Xcode", "Notes", "Mail", "Calendar", "Terminal"]
    static let icons = ["safari", "hammer", "note.text", "envelope", "calendar", "terminal"].map {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil)
    }
    static let thumbnails = (0..<6).map { Theme.previewThumbnail(index: $0) }

    static func app(index: Int) -> AppEntry {
        let name = names[index % names.count]
        return AppEntry(pid: pid_t(index + 1), bundleIdentifier: nil,
                        name: index < names.count ? name : "\(name) \(index / names.count + 1)",
                        icon: icons[index % icons.count], windows: [])
    }
}
