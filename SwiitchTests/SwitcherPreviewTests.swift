import AppKit
import SwiftUI
@testable import Swiitch
import XCTest

@MainActor
final class SwitcherPreviewTests: XCTestCase {
    func testRenderMinimizedWindowsWithCachedPreviewsAtCompactAndNormalSizes() throws {
        for dark in [false, true] {
            let view = VStack(spacing: 20) {
                ForEach([CGFloat(72), 220], id: \.self) { width in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<3) { index in
                            WindowCell(title: "Example document", thumbnail: Theme.previewThumbnail(index: 0),
                                appIcon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil),
                                overlayPosition: .bottomLeading, secondaryLabel: "Example app",
                                isMinimized: index != 0, isSelected: index == 2, thumbHeight: width * 0.62)
                                .frame(width: width)
                        }
                    }
                }
            }
            .frame(width: 740, height: 300)
            .background(Color(nsColor: .windowBackgroundColor))
            try attachSnapshot(view, name: "Minimized-windows-\(dark ? "dark" : "light")", dark: dark, height: 300, width: 740)
        }
    }

    func testFeedbackHeaderAndGridStayWithinPanelHeightBudget() {
        for height: CGFloat in [520, 700, 900, 1400] {
            XCTAssertEqual(SwitcherPanelSizing.maximumGridHeight(availableHeight: height)
                + SwitcherPanelSizing.verticalChrome, height)
        }
    }
    func testRenderActionFeedbackAndUnavailableControlsInBothAppearances() throws {
        for dark in [false, true] {
            let controls = WindowControlActions(close: {}, minimize: {}, zoom: {},
                capabilities: .init(close: .available, minimize: .unsupported, zoom: .disabled))
            let view = VStack(spacing: 24) {
                ActionFeedbackBadge(message: WindowActionResult.failed.message(for: .close)!)
                    .frame(width: 340, height: 44)
                WindowTrafficLightControls(actions: controls)
                WindowCell(title: "Example document", thumbnail: nil, thumbnailState: .unavailable,
                    appIcon: nil, overlayPosition: .hidden, isSelected: true, thumbHeight: 120)
                    .frame(width: 240)
            }
            .frame(width: 560, height: 350)
            .background(Color(nsColor: .windowBackgroundColor))
            try attachSnapshot(view, name: "Action-feedback-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    func testWindowPreviewUsesProductionGridMetrics() {
        for width in [30, 60, 100] {
            for count in [6, 12, 24, 40] {
                for size in Preferences.ThumbnailSize.allCases {
                    for fit in [false, true] {
                        let preview = layout(count: count, size: size, width: width, fit: fit)
                        let limits = SwitcherPanelSizing.limits(screenWidth: 1440, percent: width)
                        let expected = SwitcherLayout.gridMetrics(count: count, maxWidth: limits.grid, availableHeight: 900 - 24 - 170, thumbnailSize: size, fitAll: fit)
                        XCTAssertEqual(preview.metrics, expected)
                        XCTAssertLessThanOrEqual(preview.panelWidth, limits.panel)
                    }
                }
            }
        }
    }

    func testAutomaticKeepsThumbnailSizeAndFillUsesDifferentGrid() {
        let automatic = layout(count: 12)
        let filled = layout(count: 12, fit: true)
        XCTAssertEqual(automatic.metrics.cellWidth, Preferences.ThumbnailSize.medium.cellWidth)
        XCTAssertNotEqual(automatic.metrics, filled.metrics)
        XCTAssertFalse(filled.needsScrolling)
    }

    func testMaximumWidthChangesWrapping() {
        let narrow = layout(count: 24, width: 30)
        let wide = layout(count: 24, width: 100)
        XCTAssertLessThan(narrow.metrics.columns, wide.metrics.columns)
        XCTAssertLessThan(narrow.panelWidth, wide.panelWidth)
        XCTAssertTrue(narrow.needsScrolling)
    }

    func testSampleCountChangesRows() {
        XCTAssertLessThan(layout(count: 6).rows, layout(count: 24).rows)
    }

    func testAppPreviewUsesProductionAppColumnsAndIgnoresWindowGridSettings() {
        let a = layout(count: 12, windows: false, size: .small, fit: false)
        let b = layout(count: 12, windows: false, size: .large, fit: true)
        XCTAssertEqual(a.metrics, b.metrics)
        XCTAssertEqual(a.metrics.columns, SwitcherLayout.appGridColumns(count: 12, maxWidth: 1440 * 0.6 - 80))
    }

    func testInvalidSampleCountAndScreenSizeRemainBounded() {
        let preview = SwitcherPreviewLayout(screenSize: .zero, count: 0, isWindowsMode: true, thumbnailSize: .large, maximumWidthPercent: 0, fitAll: true)
        XCTAssertEqual(preview.count, 1)
        XCTAssertGreaterThan(preview.viewportHeight, 0)
        XCTAssertTrue(preview.panelWidth.isFinite)
    }

    func testRenderPreviewInLightDarkAndBothLayouts() throws {
        for dark in [false, true] {
            for fit in [false, true] {
                let preview = layout(count: 12, fit: fit)
                let card = SwitcherPreviewCard(layout: preview, panelMaterial: .solid,
                    cornerRadius: 16, overlayPosition: .bottomLeading, thumbnailOverlay: .none, accent: .blue)
                    .frame(width: 560, height: 350)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                try attachSnapshot(card, name: "Preview-\(dark ? "dark" : "light")-\(fit ? "fill" : "automatic")", dark: dark)
            }
        }
    }

    func testRenderFixedMaterialsAgainstOppositeAppAppearance() throws {
        for windows in [true, false] {
            for dark in [false, true] {
                let material: Preferences.PanelMaterial = dark ? .solidLight : .solidDark
                let card = SwitcherPreviewCard(layout: layout(count: 6, windows: windows), panelMaterial: material,
                    cornerRadius: 16, overlayPosition: .bottomLeading, thumbnailOverlay: .none, accent: .blue)
                    .frame(width: 560, height: 350)
                    .background(Color(nsColor: .windowBackgroundColor))
                try attachSnapshot(card, name: "Contrast-\(material.rawValue)-\(windows ? "windows" : "apps")", dark: dark)
            }
        }
    }

    func testRenderThumbnailStatesAtCompactAndNormalSizes() throws {
        for dark in [false, true] {
            let grid = VStack(spacing: 16) {
                ForEach([CGFloat(72), 160], id: \.self) { width in
                    HStack(spacing: 12) {
                        ForEach([ThumbnailState.loading, .unavailable, .permissionRequired], id: \.label) { state in
                            WindowCell(title: "Example window", thumbnail: nil, thumbnailState: state,
                                appIcon: nil, overlayPosition: .hidden, isSelected: false, thumbHeight: width * 0.62)
                                .frame(width: width)
                        }
                    }
                }
            }
            .frame(width: 560, height: 350)
            .background(Color(nsColor: .windowBackgroundColor))
            try attachSnapshot(grid, name: "Thumbnail-states-\(dark ? "dark" : "light")", dark: dark)
        }
    }

    func testRenderAppsPreview() throws {
        let card = SwitcherPreviewCard(layout: layout(count: 24, windows: false), panelMaterial: .solid,
            cornerRadius: 16, overlayPosition: .topTrailing, thumbnailOverlay: .none, accent: .purple)
            .frame(width: 560, height: 350)
            .background(Color(nsColor: .windowBackgroundColor))
        try attachSnapshot(card, name: "Preview-apps", dark: false)
    }

    func testRenderGeneralAndDiagnosticsInLightAndDark() throws {
        for dark in [false, true] {
            let preferences = PreferencesView().frame(width: 780, height: 650)
            try attachSnapshot(preferences, name: "General-services-\(dark ? "dark" : "light")", dark: dark, height: 650, width: 780)
            try attachSnapshot(DiagnosticsView(), name: "Diagnostics-\(dark ? "dark" : "light")", dark: dark, height: 500, width: 560)
        }
    }

    func testRenderLayoutControlsPreviewWhileAppsModeIsSelected() throws {
        let suite = "SwitcherPreviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        defaults.set(Preferences.PanelMaterial.solid.rawValue, forKey: Preferences.Key.panelMaterial)
        defaults.set(30, forKey: Preferences.Key.maxPanelWidthPercent)
        defaults.set(true, forKey: Preferences.Key.fitWindowGridToScreen)
        let preview = SwitcherPreview(showsWindowGrid: true)
            .defaultAppStorage(defaults)
            .padding(20)
            .frame(width: 560, height: 450, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        try attachSnapshot(preview, name: "Preview-controls-apps-mode-30-percent", dark: true, height: 450)
    }

    private func attachSnapshot<V: View>(_ view: V, name: String, dark: Bool, height: CGFloat = 350, width: CGFloat = 560) throws {
        // ImageRenderer omits AppKit-backed ScrollView content. Host offscreen
        // and snapshot the real view hierarchy without showing or focusing it.
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func layout(count: Int, windows: Bool = true, size: Preferences.ThumbnailSize = .medium, width: Int = 60, fit: Bool = false) -> SwitcherPreviewLayout {
        SwitcherPreviewLayout(screenSize: CGSize(width: 1440, height: 900), count: count, isWindowsMode: windows, thumbnailSize: size, maximumWidthPercent: width, fitAll: fit)
    }
}
