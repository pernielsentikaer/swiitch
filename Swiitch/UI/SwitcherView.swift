import SwiftUI

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    @AppStorage(Preferences.Key.accentColorHex) private var accentColorHex: String = ""
    @AppStorage(Preferences.Key.thumbnailSize) private var thumbnailSizeRaw: String = Preferences.ThumbnailSize.medium.rawValue
    @AppStorage(Preferences.Key.panelMaterial) private var panelMaterialRaw: String = Preferences.PanelMaterial.translucentLight.rawValue
    @AppStorage(Preferences.Key.panelCornerRadius) private var panelCornerRadius: Int = 16
    @AppStorage(Preferences.Key.overlayPosition) private var overlayPositionRaw: String = Preferences.OverlayPosition.bottomLeading.rawValue

    private var tint: Color {
        Color(hex: accentColorHex) ?? .accentColor
    }

    private var thumbnailSize: Preferences.ThumbnailSize {
        Preferences.ThumbnailSize(rawValue: thumbnailSizeRaw) ?? .medium
    }

    private var panelMaterial: Preferences.PanelMaterial {
        Preferences.PanelMaterial(rawValue: panelMaterialRaw) ?? .translucentLight
    }

    private var overlayPosition: Preferences.OverlayPosition {
        Preferences.OverlayPosition(rawValue: overlayPositionRaw) ?? .bottomLeading
    }

    var body: some View {
        VStack(spacing: 14) {
            // Floating search field sits above the panel. Rendered with reserved height
            // so the panel never resizes when the filter appears/disappears.
            FilterField(text: model.filterText)
                .opacity(model.filterText.isEmpty ? 0 : 1)
                .scaleEffect(model.filterText.isEmpty ? 0.96 : 1.0, anchor: .bottom)
                .animation(.easeOut(duration: 0.15), value: model.filterText.isEmpty)
                .frame(maxWidth: 520)

            Group {
                switch model.mode {
                case .apps:
                    AppGridView(model: model, maxWidth: model.effectiveMaxWidth)
                        .padding(20)
                case .windowsForApp:
                    if let app = model.currentApp, app.windows.count > 1 {
                        WindowGridView(
                            model: model,
                            app: app,
                            maxWidth: model.effectiveMaxWidth,
                            thumbnailSize: thumbnailSize,
                            overlayPosition: overlayPosition
                        )
                        .padding(20)
                    }
                case .flatWindows:
                    FlatWindowGridView(
                        model: model,
                        maxWidth: model.effectiveMaxWidth,
                        thumbnailSize: thumbnailSize,
                        overlayPosition: overlayPosition
                    )
                    .padding(20)
                }
            }
            .background(Theme.panelBackground(material: panelMaterial, cornerRadius: CGFloat(panelCornerRadius)))
        }
        .padding(20)
        .environment(\.swiitchAccent, tint)
        .tint(tint)
    }
}

private struct NoMatchesView: View {
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.secondary)
            Text("No matches")
                .font(.headline)
            if !query.isEmpty {
                Text("No apps or windows match \"\(query)\"")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
}

/// Spotlight-style search field. Wide, prominent, with a large magnifying glass on
/// the left, the typed query in big rounded type, a blinking cursor for the I-beam
/// feel, and an unobtrusive hint on the right.
private struct FilterField: View {
    let text: String
    @Environment(\.swiitchAccent) private var accent: Color
    @State private var cursorVisible: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accent)

            ZStack(alignment: .leading) {
                Text(text)
                    .font(.system(size: 22, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                // Blinking caret to make the field read as "input" rather than "label".
                Rectangle()
                    .fill(accent)
                    .frame(width: 2, height: 24)
                    .offset(x: caretX, y: 0)
                    .opacity(cursorVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: cursorVisible)
            }

            Spacer(minLength: 12)

            Text("⌫ to delete")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(accent.opacity(0.45), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 6)
        )
        .onAppear { cursorVisible = false } // triggers the autoreverses toggle
    }

    /// Rough offset of the caret past the end of typed text. We don't have access to
    /// real text-layout metrics here, so we estimate from string length × glyph width.
    /// Good enough for the "typing visualizer" effect.
    private var caretX: CGFloat {
        let estimatedGlyph: CGFloat = 13.5
        return min(CGFloat(text.count) * estimatedGlyph, 460)
    }
}

// MARK: - Apps grid

private struct AppGridView: View {
    @ObservedObject var model: SwitcherModel
    let maxWidth: CGFloat

    private let cellWidth: CGFloat = 110
    private let cellSpacing: CGFloat = 14

    var body: some View {
        let visible = model.filteredApps
        if visible.isEmpty {
            NoMatchesView(query: model.filterText)
                .frame(maxWidth: maxWidth)
        } else {
            appGrid(visible: visible)
        }
    }

    private func appGrid(visible: [AppEntry]) -> some View {
        let columnsCount = max(1, min(visible.count, Int(maxWidth / (cellWidth + cellSpacing))))
        let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: cellSpacing), count: columnsCount)

        return LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
            ForEach(visible, id: \.id) { app in
                let absoluteIndex = model.apps.firstIndex(of: app) ?? 0
                let isPinned = Preferences.isPinned(app.bundleIdentifier)
                AppCell(app: app, isSelected: absoluteIndex == model.selectedAppIndex, isPinned: isPinned)
                    .frame(width: cellWidth)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            model.selectApp(at: absoluteIndex)
                            model.schedulePeekIfEnabled()
                        } else {
                            model.cancelPendingPeek()
                        }
                    }
                    .onTapGesture {
                        if model.mouseHasMoved {
                            model.selectApp(at: absoluteIndex)
                        }
                        model.commit()
                    }
                    .contextMenu {
                        if let bid = app.bundleIdentifier {
                            Button(isPinned ? "Unpin from top" : "Pin to top") {
                                Preferences.togglePinned(bid)
                                model.refreshAfterPinChange()
                            }
                            Button("Exclude from Swiitch") {
                                Preferences.excludeApp(bid)
                                model.refreshAfterAppListPreferenceChange()
                            }
                        }
                    }
            }
        }
        .frame(maxWidth: maxWidth)
    }
}

private struct AppCell: View {
    let app: AppEntry
    let isSelected: Bool
    var isPinned: Bool = false
    @Environment(\.swiitchAccent) private var accent: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.35) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? accent : .clear, lineWidth: 2)
                    )
                    .frame(width: 92, height: 92)

                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .frame(width: 56, height: 56)
                        .foregroundStyle(.secondary)
                }

                if isPinned {
                    VStack {
                        HStack {
                            Image(systemName: "pin.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(accent.opacity(0.9)))
                                .padding(4)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                if app.windows.count > 1 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(app.windows.count)")
                                .font(.caption2.monospacedDigit().bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                }
            }

            Text(app.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 100)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
    }
}

// MARK: - Per-app window grid (used when drilled in from apps mode)

private struct WindowGridView: View {
    @ObservedObject var model: SwitcherModel
    let app: AppEntry
    let maxWidth: CGFloat
    let thumbnailSize: Preferences.ThumbnailSize
    let overlayPosition: Preferences.OverlayPosition

    @AppStorage(Preferences.Key.tileColumns) private var tileColumns: Int = 0
    private let cellSpacing: CGFloat = 12

    var body: some View {
        let count = app.windows.count
        let fillCols: Int = {
            if tileColumns == -1 {
                return SwitcherModel.computeFillColumns(count: count, maxWidth: maxWidth,
                                                        availableHeight: model.effectiveMaxHeight - 300)
            }
            return tileColumns > 0 ? min(tileColumns, count) : 0
        }()
        let cellWidth: CGFloat = fillCols > 0
            ? max(120, (maxWidth - cellSpacing * CGFloat(fillCols - 1)) / CGFloat(fillCols))
            : thumbnailSize.cellWidth
        let thumbHeight: CGFloat = fillCols > 0 ? cellWidth * 0.625 : thumbnailSize.thumbHeight
        let columnsCount = max(1, fillCols > 0 ? fillCols : min(count, Int(maxWidth / (cellWidth + cellSpacing))))
        let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: cellSpacing), count: columnsCount)

        LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
            ForEach(Array(app.windows.enumerated()), id: \.element.id) { index, window in
                WindowCell(
                    title: window.displayTitle,
                    thumbnail: model.thumbnails[window.id],
                    appIcon: app.icon,
                    overlayPosition: overlayPosition,
                    isSelected: index == model.selectedWindowIndex,
                    thumbHeight: thumbHeight,
                    isOnScreen: window.isOnScreen
                )
                .frame(width: cellWidth)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        model.selectWindow(at: index)
                        model.schedulePeekIfEnabled()
                    } else {
                        model.cancelPendingPeek()
                    }
                }
                .onTapGesture {
                    if model.mouseHasMoved {
                        model.selectWindow(at: index)
                    }
                    model.commit()
                }
            }
        }
        .frame(maxWidth: maxWidth)
    }
}

// MARK: - Flat windows grid (windows display mode)

private struct FlatWindowGridView: View {
    @ObservedObject var model: SwitcherModel
    let maxWidth: CGFloat
    let thumbnailSize: Preferences.ThumbnailSize
    let overlayPosition: Preferences.OverlayPosition

    @AppStorage(Preferences.Key.tileColumns) private var tileColumns: Int = 0
    private let cellSpacing: CGFloat = 12

    var body: some View {
        let visible = model.filteredFlatWindows
        if visible.isEmpty {
            NoMatchesView(query: model.filterText)
                .frame(maxWidth: maxWidth)
        } else {
            grid(visible: visible)
        }
    }

    private func grid(visible: [SwitcherModel.FlatWindowEntry]) -> some View {
        let count = visible.count
        let fillCols: Int = {
            if tileColumns == -1 {
                return SwitcherModel.computeFillColumns(count: count, maxWidth: maxWidth,
                                                        availableHeight: model.effectiveMaxHeight - 150)
            }
            return tileColumns > 0 ? min(tileColumns, count) : 0
        }()
        let cellWidth: CGFloat = fillCols > 0
            ? max(120, (maxWidth - cellSpacing * CGFloat(fillCols - 1)) / CGFloat(fillCols))
            : thumbnailSize.cellWidth
        let thumbHeight: CGFloat = fillCols > 0 ? cellWidth * 0.625 : thumbnailSize.thumbHeight
        let columnsCount = max(1, fillCols > 0 ? fillCols : min(count, Int(maxWidth / (cellWidth + cellSpacing))))
        let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: cellSpacing), count: columnsCount)

        return LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
            ForEach(visible, id: \.id) { entry in
                let absoluteIndex = model.flatWindows.firstIndex(of: entry) ?? 0
                WindowCell(
                    title: entry.window.displayTitle,
                    thumbnail: model.thumbnails[entry.id],
                    appIcon: entry.appIcon,
                    overlayPosition: overlayPosition,
                    secondaryLabel: entry.appName,
                    isSelected: absoluteIndex == model.selectedFlatIndex,
                    thumbHeight: thumbHeight,
                    isOnScreen: entry.window.isOnScreen
                )
                .frame(width: cellWidth)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        model.selectFlatWindow(at: absoluteIndex)
                        model.schedulePeekIfEnabled()
                    } else {
                        model.cancelPendingPeek()
                    }
                }
                .onTapGesture {
                    if model.mouseHasMoved {
                        model.selectFlatWindow(at: absoluteIndex)
                    }
                    model.commit()
                }
            }
        }
        .frame(maxWidth: maxWidth)
    }
}

// MARK: - Window cell (used in both window grid views)

private struct WindowCell: View {
    let title: String
    let thumbnail: NSImage?
    let appIcon: NSImage?
    let overlayPosition: Preferences.OverlayPosition
    var secondaryLabel: String? = nil
    let isSelected: Bool
    let thumbHeight: CGFloat
    var isOnScreen: Bool = true

    @Environment(\.swiitchAccent) private var accent: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: overlayPosition.swiftAlignment) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.15) : Color.primary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSelected ? accent : Color.primary.opacity(0.1),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(4)
                        .transition(.opacity)
                } else {
                    Text(title)
                        .font(.callout)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if overlayPosition != .hidden, let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .padding(6)
                }

                // Off-screen / other-Space indicator. We can't tell *which* Space a
                // window is on without private SPIs, but `isOnScreen=false` is a clear
                // signal it's not currently visible — likely on another Space or hidden.
                if !isOnScreen {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .padding(6)
                        }
                        Spacer()
                    }
                }
            }
            .frame(height: thumbHeight)

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                if let secondaryLabel {
                    Text(secondaryLabel)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
