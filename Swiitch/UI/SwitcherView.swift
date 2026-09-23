import SwiftUI

private enum SwitcherScrollTarget: Hashable {
    case app(pid_t)
    case window(CGWindowID)
}

/// Viewport-local geometry, not LazyVGrid's prefetched/on-appear cell set.
struct ThumbnailViewportLayout: Equatable {
    var context: SwitcherModel.ThumbnailViewportContext?
    var bounds: CGRect?
    var windowFrames: [CGWindowID: CGRect] = [:]

    var visibleWindowIDs: Set<CGWindowID> {
        guard let bounds, !bounds.isEmpty else { return [] }
        return Set(windowFrames.compactMap { id, frame in
            let overlap = bounds.intersection(frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0 ? id : nil
        })
    }

    mutating func merge(_ other: Self) {
        context = other.context ?? context
        bounds = other.bounds ?? bounds
        windowFrames.merge(other.windowFrames, uniquingKeysWith: { _, newer in newer })
    }
}

private struct ThumbnailViewportPreference: PreferenceKey {
    static let defaultValue = ThumbnailViewportLayout()
    static func reduce(value: inout ThumbnailViewportLayout, nextValue: () -> ThumbnailViewportLayout) {
        value.merge(nextValue())
    }
}

private struct ThumbnailFrameReporter: View {
    static let coordinateSpace = "Swiitch.thumbnailViewport"
    let id: CGWindowID

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ThumbnailViewportPreference.self,
                value: ThumbnailViewportLayout(windowFrames: [id: geometry.frame(in: .named(Self.coordinateSpace))]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    @AppStorage(Preferences.Key.accentColorHex) private var accentColorHex: String = ""
    @AppStorage(Preferences.Key.thumbnailSize) private var thumbnailSizeRaw: String = Preferences.ThumbnailSize.medium.rawValue
    @AppStorage(Preferences.Key.panelMaterial) private var panelMaterialRaw: String = Preferences.PanelMaterial.translucentLight.rawValue
    @AppStorage(Preferences.Key.panelCornerRadius) private var panelCornerRadius: Int = 16
    @AppStorage(Preferences.Key.overlayPosition) private var overlayPositionRaw: String = Preferences.OverlayPosition.bottomLeading.rawValue
    @AppStorage(Preferences.Key.thumbnailOverlay) private var thumbnailOverlayRaw: String = Preferences.ThumbnailOverlay.none.rawValue

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

    private var thumbnailOverlay: Preferences.ThumbnailOverlay {
        Preferences.ThumbnailOverlay(rawValue: thumbnailOverlayRaw) ?? .none
    }

    private var selectedScrollTarget: SwitcherScrollTarget? {
        switch model.mode {
        case .apps:
            guard model.apps.indices.contains(model.selectedAppIndex) else { return nil }
            return .app(model.apps[model.selectedAppIndex].pid)
        case .windowsForApp:
            guard let window = model.selectedVisibleAppWindow else { return nil }
            return .window(window.id)
        case .flatWindows, .currentAppWindows:
            guard model.flatWindows.indices.contains(model.selectedFlatIndex) else { return nil }
            return .window(model.flatWindows[model.selectedFlatIndex].id)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // Floating search bar sits above the panel. Rendered with reserved height
            // so the panel never resizes when the filter appears/disappears.
            ZStack {
                FilterBadge(text: model.filterText)
                    .opacity(model.filterText.isEmpty || model.actionFeedback != nil ? 0 : 1)
                    .accessibilityHidden(model.filterText.isEmpty || model.actionFeedback != nil)
                if let message = model.actionFeedback { ActionFeedbackBadge(message: message) }
            }
            .frame(maxWidth: min(380, model.effectiveMaxWidth))
            .frame(height: 44)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Group {
                        switch model.mode {
                        case .apps:
                            AppGridView(model: model, maxWidth: model.effectiveMaxWidth)
                                .padding(20)
                        case .windowsForApp:
                            VStack(spacing: 0) {
                                AppGridView(model: model, maxWidth: model.effectiveMaxWidth)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 20)
                                    .padding(.bottom, 8)
                                Divider().padding(.horizontal, 20)
                                if let app = model.currentApp {
                                    WindowGridView(
                                        model: model,
                                        app: app,
                                        maxWidth: model.effectiveMaxWidth,
                                        thumbnailSize: thumbnailSize,
                                        overlayPosition: overlayPosition,
                                        thumbnailOverlay: thumbnailOverlay
                                    )
                                    .padding(20)
                                }
                            }
                        case .flatWindows, .currentAppWindows:
                            FlatWindowGridView(
                                model: model,
                                maxWidth: model.effectiveMaxWidth,
                                thumbnailSize: thumbnailSize,
                                overlayPosition: overlayPosition,
                                thumbnailOverlay: thumbnailOverlay
                            )
                            .padding(20)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: ThumbnailFrameReporter.coordinateSpace)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ThumbnailViewportPreference.self,
                            value: ThumbnailViewportLayout(context: model.thumbnailViewportContext,
                                bounds: CGRect(origin: .zero, size: geometry.size)))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(ThumbnailViewportPreference.self) { layout in
                    guard let context = layout.context, layout.bounds != nil else { return }
                    model.updateThumbnailViewport(layout.visibleWindowIDs, context: context)
                }
                .onChange(of: selectedScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: SwitcherPanelSizing.maximumGridHeight(availableHeight: model.effectiveMaxHeight))
            .background(Theme.panelBackground(material: panelMaterial, cornerRadius: CGFloat(panelCornerRadius)))
        }
        .padding(20)
        .environment(\.swiitchAccent, tint)
        .tint(tint)
        .swiitchPanelAppearance(material: panelMaterial)
        .onChange(of: model.actionFeedback) { _, message in
            guard let message else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }
}

/// Uses the search badge's reserved space, so failures never move the pointer targets.
struct ActionFeedbackBadge: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .help(message)
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

private struct FilterBadge: View {
    let text: String
    @Environment(\.swiitchAccent) private var accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout.weight(.medium))
                .foregroundStyle(accent)
            Text(text.isEmpty ? " " : text)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text("⌫ to delete")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(accent.opacity(0.5), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        )
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
        let columnsCount = SwitcherModel.appGridColumns(count: visible.count, maxWidth: maxWidth)
        let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: cellSpacing), count: columnsCount)

        return LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
            ForEach(visible, id: \.id) { app in
                let absoluteIndex = model.apps.firstIndex(of: app) ?? 0
                let isPinned = Preferences.isPinned(app.bundleIdentifier)
                AppCell(app: app, isSelected: absoluteIndex == model.selectedAppIndex, isPinned: isPinned)
                    .id(SwitcherScrollTarget.app(app.pid))
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
                        model.commitApp(id: app.id)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.commitApp(id: app.id) }
                    .accessibilityActions {
                        Button("Choose a window") {
                            model.chooseWindows(of: app.id)
                        }
                    }
                    .contextMenu {
                        if let bid = app.bundleIdentifier {
                            Button(isPinned ? String(localized: "Unpin from top") : String(localized: "Pin to top")) {
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

struct AppCell: View {
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
                            HStack(spacing: 3) {
                                if isSelected {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                Text("\(app.windows.count)")
                                    .font(.caption2.monospacedDigit().bold())
                            }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .foregroundStyle(.white)
                                .padding(6)
                                .accessibilityHidden(true)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(app.windows.count == 1 ? String(localized: "1 window") : String(localized: "\(app.windows.count) windows"))
        .accessibilityHint(
            app.windows.count > 1
                ? String(localized: "Press Down Arrow to choose a window.")
                : String(localized: "Press Return to switch to this app.")
        )
    }
}

// MARK: - Per-app window grid (used when drilled in from apps mode)

private struct WindowGridView: View {
    @ObservedObject var model: SwitcherModel
    let app: AppEntry
    let maxWidth: CGFloat
    let thumbnailSize: Preferences.ThumbnailSize
    let overlayPosition: Preferences.OverlayPosition
    let thumbnailOverlay: Preferences.ThumbnailOverlay

    @AppStorage(Preferences.Key.showWindowControlsOnHover) private var showWindowControlsOnHover = false

    private let cellSpacing: CGFloat = 12

    var body: some View {
        let visible = model.filteredAppWindows
        if visible.isEmpty {
            NoMatchesView(query: model.filterText)
                .frame(maxWidth: maxWidth)
        } else {
            windowGrid(visible: visible)
        }
    }

    private func windowGrid(visible: [WindowInfo]) -> some View {
        let metrics = model.gridMetrics(count: visible.count, for: .windowsForApp)
        let columns = Array(
            repeating: GridItem(.fixed(metrics.cellWidth), spacing: cellSpacing),
            count: metrics.columns
        )

        return LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
            ForEach(visible) { window in
                let index = app.windows.firstIndex(where: { $0.id == window.id }) ?? 0
                WindowCell(
                    title: window.displayTitle,
                    thumbnail: model.thumbnails[window.id],
                    thumbnailState: model.thumbnailState(for: window.id),
                    appIcon: app.icon,
                    accessibilityAppName: app.name,
                    overlayPosition: overlayPosition,
                    thumbnailOverlay: thumbnailOverlay,
                    isMinimized: window.isMinimized == true,
                    isSelected: index == model.selectedWindowIndex,
                    thumbHeight: metrics.thumbnailHeight,
                    showControlsOnHover: showWindowControlsOnHover && model.mouseHasMoved,
                    controls: WindowControlActions(
                        close: { _ = model.closeWindow(id: window.id) },
                        minimize: { _ = model.minimizeWindow(id: window.id) },
                        zoom: { _ = model.zoomWindow(id: window.id) },
                        capabilities: model.windowCapabilities[window.id] ?? .init()
                    ),
                    prepareControls: { model.prepareWindowControls(id: window.id) },
                    hoverChanged: { hovering in
                        if hovering {
                            model.selectWindow(at: index)
                            model.schedulePeekIfEnabled()
                        } else {
                            model.cancelPendingPeek()
                        }
                    },
                    commit: {
                        model.commitWindow(id: window.id)
                    }
                )
                .id(SwitcherScrollTarget.window(window.id))
                .frame(width: metrics.cellWidth)
                .background(ThumbnailFrameReporter(id: window.id))
                .contentShape(Rectangle())
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
    let thumbnailOverlay: Preferences.ThumbnailOverlay

    @AppStorage(Preferences.Key.showWindowControlsOnHover) private var showWindowControlsOnHover = false

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
        let metrics = model.gridMetrics(count: visible.count, for: .flatWindows)
        let columns = Array(
            repeating: GridItem(.fixed(metrics.cellWidth), spacing: cellSpacing),
            count: metrics.columns
        )

        return LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
            ForEach(visible, id: \.id) { entry in
                let absoluteIndex = model.flatWindows.firstIndex(of: entry) ?? 0
                WindowCell(
                    title: entry.window.displayTitle,
                    thumbnail: model.thumbnails[entry.id],
                    thumbnailState: model.thumbnailState(for: entry.id),
                    appIcon: entry.appIcon,
                    overlayPosition: overlayPosition,
                    thumbnailOverlay: thumbnailOverlay,
                    secondaryLabel: entry.appName,
                    isMinimized: entry.window.isMinimized == true,
                    isSelected: absoluteIndex == model.selectedFlatIndex,
                    thumbHeight: metrics.thumbnailHeight,
                    showControlsOnHover: showWindowControlsOnHover && model.mouseHasMoved,
                    controls: WindowControlActions(
                        close: { _ = model.closeWindow(id: entry.id) },
                        minimize: { _ = model.minimizeWindow(id: entry.id) },
                        zoom: { _ = model.zoomWindow(id: entry.id) },
                        capabilities: model.windowCapabilities[entry.id] ?? .init()
                    ),
                    prepareControls: { model.prepareWindowControls(id: entry.id) },
                    hoverChanged: { hovering in
                        if hovering {
                            model.selectFlatWindow(at: absoluteIndex)
                            model.schedulePeekIfEnabled()
                        } else {
                            model.cancelPendingPeek()
                        }
                    },
                    commit: {
                        model.commitWindow(id: entry.id)
                    }
                )
                .id(SwitcherScrollTarget.window(entry.id))
                .frame(width: metrics.cellWidth)
                .background(ThumbnailFrameReporter(id: entry.id))
                .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: maxWidth)
    }
}

// MARK: - Window cell (used in both window grid views)

struct WindowControlActions {
    let close: () -> Void
    let minimize: () -> Void
    let zoom: () -> Void
    var capabilities = WindowActionCapabilities()
}

struct WindowCell: View {
    let title: String
    let thumbnail: NSImage?
    var thumbnailState: ThumbnailState = .loading
    let appIcon: NSImage?
    var accessibilityAppName: String? = nil
    let overlayPosition: Preferences.OverlayPosition
    var thumbnailOverlay: Preferences.ThumbnailOverlay = .none
    var secondaryLabel: String? = nil
    var isMinimized: Bool = false
    let isSelected: Bool
    let thumbHeight: CGFloat
    var showControlsOnHover: Bool = false
    var controls: WindowControlActions? = nil
    var prepareControls: (() -> Void)? = nil
    var hoverChanged: ((Bool) -> Void)? = nil
    var commit: (() -> Void)? = nil

    @Environment(\.swiitchAccent) private var accent: Color
    @State private var isHovering = false
    @State private var isHoveringControls = false

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
                        .overlay(thumbnailOverlayLayer)
                        .opacity(isMinimized ? Theme.minimizedThumbnailOpacity : 1)
                        .transition(.opacity)
                } else {
                    ThumbnailPlaceholder(state: thumbnailState)
                }

                if overlayPosition != .hidden, let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .padding(6)
                        .opacity(showsControls && overlayPosition == .topLeading ? 0 : 1)
                }

                if showsControls, let controls {
                    VStack {
                        HStack {
                            WindowTrafficLightControls(actions: controls)
                                .onHover { isHoveringControls = $0 }
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(7)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topLeading)))
                }

            }
            .frame(height: thumbHeight)

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                if secondaryLabel != nil || isMinimized {
                    if isMinimized {
                        ViewThatFits(in: .horizontal) {
                            if let secondaryLabel {
                                HStack(spacing: 3) {
                                    Text(secondaryLabel).foregroundStyle(.tertiary)
                                    Text("·").foregroundStyle(.secondary)
                                    Text("Minimized").foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            // Keep the status readable even at the grid's smallest tile size.
                            Text("Minimized")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                        .lineLimit(1)
                    } else if let secondaryLabel {
                        Text(secondaryLabel)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28, alignment: .top)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { prepareControls?() }
            if !hovering { isHoveringControls = false }
            hoverChanged?(hovering)
        }
        .onAppear { if isSelected { prepareControls?() } }
        .onChange(of: isSelected) { _, selected in if selected { prepareControls?() } }
        .onTapGesture {
            guard !isHoveringControls else { return }
            commit?()
        }
        .animation(.easeOut(duration: 0.12), value: showsControls)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, accessibilityAppName ?? secondaryLabel].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue([
            isMinimized ? String(localized: "Minimized") : nil,
            thumbnail == nil ? thumbnailState.label : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isMinimized
            ? String(localized: "Activate to restore and switch to this window. Window actions are available in the Actions menu.")
            : String(localized: "Activate to switch to this window. Window actions are available in the Actions menu."))
        .accessibilityAction { commit?() }
        .accessibilityActions {
            if let controls {
                if controls.capabilities.close.canAttempt { Button(String(localized: "Close window"), action: controls.close) }
                if controls.capabilities.minimize.canAttempt { Button(String(localized: "Minimize window"), action: controls.minimize) }
                if controls.capabilities.zoom.canAttempt { Button(String(localized: "Zoom or restore window"), action: controls.zoom) }
            }
        }
    }

    private var showsControls: Bool {
        showControlsOnHover && isHovering && controls != nil
    }

    /// Decorative layer rendered on top of the captured thumbnail. Clipped to the inner
    /// rounded shape so it never spills outside the cell border.
    @ViewBuilder
    private var thumbnailOverlayLayer: some View {
        switch thumbnailOverlay {
        case .none:
            EmptyView()
        case .gradientEdges:
            // Two accent-colored gradients hugging the top and bottom edges. Subtle on
            // light themes, punchy on dark — exactly what the Synthwave preset wants.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: accent.opacity(0.55), location: 0.0),
                            .init(color: accent.opacity(0.0),  location: 0.18),
                            .init(color: accent.opacity(0.0),  location: 0.82),
                            .init(color: accent.opacity(0.55), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        case .scanlines:
            // 2-pixel-tall horizontal lines every 4 pixels — CRT-style.
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
            .allowsHitTesting(false)
        case .tint:
            // Soft accent multiply across the whole thumbnail.
            accent.opacity(0.22)
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
    }
}

struct WindowTrafficLightControls: View {
    let actions: WindowControlActions

    var body: some View {
        HStack(spacing: 3) {
            trafficLight(
                color: Color(red: 1.0, green: 0.37, blue: 0.34),
                symbol: "xmark",
                label: String(localized: "Close window"),
                help: actions.capabilities.close.help(for: .close),
                enabled: actions.capabilities.close.canAttempt,
                action: actions.close
            )
            trafficLight(
                color: Color(red: 1.0, green: 0.74, blue: 0.18),
                symbol: "minus",
                label: String(localized: "Minimize window"),
                help: actions.capabilities.minimize.help(for: .minimize),
                enabled: actions.capabilities.minimize.canAttempt,
                action: actions.minimize
            )
            trafficLight(
                color: Color(red: 0.16, green: 0.78, blue: 0.25),
                symbol: "arrow.up.left.and.arrow.down.right",
                label: String(localized: "Zoom or restore window"),
                help: actions.capabilities.zoom.help(for: .zoom),
                enabled: actions.capabilities.zoom.canAttempt,
                action: actions.zoom
            )
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private func trafficLight(
        color: Color,
        symbol: String,
        label: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(enabled ? color : Color.secondary.opacity(0.35))
                Image(systemName: symbol)
                    .font(.system(size: 5.5, weight: .black))
                    .foregroundStyle(.black.opacity(0.58))
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(width: 17, height: 17)
        .accessibilityLabel(label)
        .help(help)
    }
}
