import AppKit
import SwiftUI

struct SwitcherPanelSizing {
    /// The grid is inset 20 points inside the panel surface, which is itself inset 20
    /// points inside the hosting view: 40 points on each horizontal edge in total.
    static let horizontalChrome: CGFloat = 80
    /// Fixed feedback/search badge (44), stack spacing (10), and outer padding (40).
    static let verticalChrome: CGFloat = 94

    static func maximumGridHeight(availableHeight: CGFloat) -> CGFloat {
        max(140, availableHeight - verticalChrome)
    }
    static let minimumPanelWidth: CGFloat = 400
    static let minimumPanelHeight: CGFloat = 140
    static let verticalScreenMargin: CGFloat = 12

    static func limits(screenWidth: CGFloat, percent: Int) -> (panel: CGFloat, grid: CGFloat) {
        let clampedPercent = max(30, min(percent, 100))
        let panel = screenWidth * CGFloat(clampedPercent) / 100.0
        let grid = max(120, panel - horizontalChrome)
        return (panel, grid)
    }

    static func panelWidth(fittingWidth: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        let minimumWidth = min(minimumPanelWidth, maximumWidth)
        return min(max(fittingWidth, minimumWidth), maximumWidth)
    }

    static func panelHeight(fittingHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let maximumHeight = max(
            minimumPanelHeight,
            screenHeight - verticalScreenMargin * 2
        )
        return min(max(fittingHeight, minimumPanelHeight), maximumHeight)
    }

    static func clampedFrame(
        size: CGSize,
        preferredOrigin: CGPoint,
        visibleFrame: CGRect
    ) -> CGRect {
        let maximumX = visibleFrame.maxX - size.width
        let maximumY = visibleFrame.maxY - size.height
        let x = min(max(preferredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, maximumX))
        let y = min(max(preferredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, maximumY))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

final class SwitcherPanel: NSPanel {
    private let model: SwitcherModel
    private var hostingView: NSHostingView<SwitcherView>!
    private var mouseMonitor: Any?
    private var initialMouseLocation: NSPoint?
    private var reflowWorkItem: DispatchWorkItem?

    init(model: SwitcherModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true

        let root = SwitcherView(model: model)
        hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present() {
        reflowWorkItem?.cancel()
        reflowWorkItem = nil
        reflowAndPlace()
        installMouseMonitor()
        orderFrontRegardless()
    }

    func refresh() {
        // SwiftUI handles interior updates via the @ObservedObject. We just remeasure
        // and reframe for structural changes (mode toggle, content count change). Doing
        // this on the next run-loop turn avoids forcing AppKit layout from inside SwiftUI's
        // current layout pass.
        reflowWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reflowWorkItem = nil
            self.reflowAndPlace(keepingCenter: true)
        }
        reflowWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func dismiss() {
        reflowWorkItem?.cancel()
        reflowWorkItem = nil
        removeMouseMonitor()
        orderOut(nil)
    }

    /// Watch for genuine mouse movement after the panel opens. We use a global monitor
    /// (vs. NSTrackingArea) because the cursor might start anywhere on screen, and we
    /// want a single threshold check rather than per-cell tracking. The model exposes
    /// `mouseHasMoved`, which the SwiftUI cells consult before honoring hover.
    private func installMouseMonitor() {
        removeMouseMonitor()
        initialMouseLocation = NSEvent.mouseLocation
        model.mouseHasMoved = false

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            guard let self, let start = self.initialMouseLocation, !self.model.mouseHasMoved else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x
            let dy = now.y - start.y
            // ~6 pt threshold so a single jitter doesn't flip it.
            if dx * dx + dy * dy > 36 {
                self.model.mouseHasMoved = true
            }
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        initialMouseLocation = nil
    }

    private func reflowAndPlace(keepingCenter: Bool = false) {
        // Compute the effective wrap width based on the active screen + percentage pref,
        // and push it to the model so SwiftUI's LazyVGrid knows where to break before we
        // measure.
        let screen = activeScreen() ?? NSScreen.main
        let screenWidth = screen?.visibleFrame.width ?? 1440
        let percent = UserDefaults.standard.integer(forKey: Preferences.Key.maxPanelWidthPercent)
        let limits = SwitcherPanelSizing.limits(screenWidth: screenWidth, percent: percent)
        model.effectiveMaxWidth = limits.grid
        let screenHeight = screen?.visibleFrame.height ?? 900
        model.effectiveMaxHeight = max(
            SwitcherPanelSizing.minimumPanelHeight,
            screenHeight - SwitcherPanelSizing.verticalScreenMargin * 2
        )

        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize

        let width = SwitcherPanelSizing.panelWidth(
            fittingWidth: fitting.width,
            maximumWidth: limits.panel
        )
        let height = SwitcherPanelSizing.panelHeight(
            fittingHeight: fitting.height,
            screenHeight: screenHeight
        )

        let origin: NSPoint
        if keepingCenter {
            let current = frame
            origin = NSPoint(x: current.midX - width / 2, y: current.midY - height / 2)
        } else if let screen {
            let frame = screen.visibleFrame
            origin = NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        } else {
            origin = NSPoint(x: 100, y: 100)
        }

        let proposedSize = CGSize(width: width, height: height)
        let targetFrame = screen.map {
            SwitcherPanelSizing.clampedFrame(
                size: proposedSize,
                preferredOrigin: origin,
                visibleFrame: $0.visibleFrame
            )
        } ?? CGRect(origin: origin, size: proposedSize)
        setFrame(targetFrame, display: true, animate: false)
    }

    private func activeScreen() -> NSScreen? {
        WindowEnumerator.screenForCurrentScope()
    }
}
