import AppKit
import SwiftUI

final class SwitcherPanel: NSPanel {
    private let model: SwitcherModel
    private var hostingView: NSHostingView<SwitcherView>!
    private var mouseMonitor: Any?
    private var initialMouseLocation: NSPoint?

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
        reflowAndPlace()
        installMouseMonitor()
        orderFrontRegardless()
    }

    func refresh() {
        // SwiftUI handles interior updates via the @ObservedObject. We just remeasure
        // and reframe for structural changes (mode toggle, content count change).
        reflowAndPlace(keepingCenter: true)
    }

    func dismiss() {
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
        let percent = max(20, min(UserDefaults.standard.integer(forKey: Preferences.Key.maxPanelWidthPercent), 100))
        let effectiveMax = screenWidth * CGFloat(percent) / 100.0
        model.effectiveMaxWidth = effectiveMax
        model.effectiveMaxHeight = screen?.visibleFrame.height ?? 900

        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize

        let panelMax = effectiveMax + 80 // panel chrome / padding budget
        let width = max(min(fitting.width, panelMax), 400)
        let height = max(fitting.height, 140)

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

        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true, animate: false)
    }

    private func activeScreen() -> NSScreen? {
        WindowEnumerator.screenForCurrentScope()
    }
}

