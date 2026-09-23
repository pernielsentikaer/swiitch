import AppKit
import ApplicationServices

enum WindowFocuser {
    /// Main-thread focus requests share one fallback; background capability reads do not.
    @MainActor static let activationRetry = ActivationRetry()

    @MainActor
    static func cancelPendingActivation() {
        activationRetry.cancel()
    }

    /// Injectable delayed work keeps activation races testable without focusing real apps.
    @MainActor
    final class ActivationRetry {
        private var generation: UInt64 = 0

        /// Only retry a failed handoff from a known source, not a later app switch.
        static func isPending(targetPID: pid_t, sourcePID: pid_t?, frontmostPID: pid_t?) -> Bool {
            guard let frontmostPID else { return false }
            return frontmostPID != targetPID && frontmostPID == sourcePID
        }

        func cancel() {
            generation &+= 1
        }

        func schedule(
            ifNeeded: @escaping @MainActor () -> Bool,
            action: @escaping @MainActor () -> Void,
            using enqueue: (@escaping @MainActor () -> Void) -> Void = { callback in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { callback() }
            }
        ) {
            cancel()
            let request = generation
            enqueue { [weak self] in
                guard let self, self.generation == request else { return }
                self.cancel()
                guard ifNeeded() else { return }
                action()
            }
        }
    }

    /// Cached discovery is not authority to act. Revalidate the exact WindowServer ID
    /// and owner immediately before native focus/actions; closed/reused IDs fail closed.
    static func isWindowPresent(_ window: WindowInfo,
                                lookup: (CGWindowID) -> [[String: Any]]? = {
                                    windowServerRows(including: $0)
                                }) -> Bool {
        guard window.id != kCGNullWindowID, window.pid > 0,
              let rows = lookup(window.id) else { return false }
        return rows.contains {
            ($0[kCGWindowNumber as String] as? CGWindowID) == window.id
                && ($0[kCGWindowOwnerPID as String] as? pid_t) == window.pid
        }
    }

    /// The targeted WindowServer query can omit minimized windows even though the
    /// complete list and AX still publish them. Fall back to the complete list, then
    /// retain the same exact ID + owner check; never substitute an app's other window.
    private static func windowServerRows(including id: CGWindowID) -> [[String: Any]]? {
        let targeted = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        if targeted?.contains(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id }) == true {
            return targeted
        }
        return CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    }

    /// Focusing may recover through an app's imperfect AX bridge. Window controls must
    /// instead fail closed when the requested document can no longer be identified.
    enum MatchingPurpose {
        case focus
        case windowAction
        case restore
    }

    struct CandidateMetadata {
        let windowID: CGWindowID?
        let title: String
        let bounds: CGRect?
    }

    /// Activates an app — used when the user selected an app row without drilling into windows.
    /// We try to raise the app's frontmost window via AX first (so the right window comes forward
    /// in the case where the app has multiple), then activate the app process.
    @MainActor
    static func focus(app entry: AppEntry) {
        cancelPendingActivation()
        guard let runningApp = NSRunningApplication(processIdentifier: entry.pid) else { return }

        // The model orders this app's windows by most recent use (CG order for unseen windows).
        // The snapshot can be stale: a window may have closed since the last enumeration.
        // Try each cached window in recency order and fall back to plain app activation so
        // selecting an app row never silently does nothing.
        for window in entry.windows {
            if focus(window: window) { return }
        }
        activate(app: runningApp)
    }

    /// Activates a specific window. Raise FIRST (AX), then activate the app — reversing
    /// this order is racy on macOS 14+ because accessory apps' cross-app activation can
    /// be denied intermittently.
    ///
    /// Returns `false` when the window identity can no longer be verified (closed or
    /// reused ID, or the owning process is gone); nothing is activated in that case.
    @MainActor
    @discardableResult
    static func focus(window: WindowInfo) -> Bool {
        cancelPendingActivation()
        guard isWindowPresent(window),
              let runningApp = NSRunningApplication(processIdentifier: window.pid) else { return false }
        let wasAlreadyActive = runningApp.isActive
        let didRaise = raise(window: window)

        // Swiitch's panel is non-activating, so the source app remains active while the
        // picker is open. Calling activate() again after raising another window can make
        // Chromium-family apps restore the window that was main before the picker opened.
        guard !wasAlreadyActive else { return true }
        activate(app: runningApp, window: window)

        // For an inactive app, activation is still needed to move the whole process to the
        // front. Reassert the exact window afterward so activation cannot replace the user's
        // selection with that app's previously-main window.
        if didRaise {
            _ = raise(window: window)
        }
        return true
    }

    /// Undo a preview only when the original process/window identity can still be resolved.
    /// Never use the ordinary focus path's title or single-window fallback for cancellation.
    @MainActor
    static func restoreFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        cancelPendingActivation()
        guard pid > 0, windowID != kCGNullWindowID,
              let runningApp = NSRunningApplication(processIdentifier: pid) else { return false }
        let target = WindowInfo(id: windowID, pid: pid, title: "", bounds: .zero, isOnScreen: false)
        let wasAlreadyActive = runningApp.isActive
        guard raise(window: target, purpose: .restore) else { return false }
        guard !wasAlreadyActive else { return true }
        activate(app: runningApp, window: target)
        return raise(window: target, purpose: .restore)
    }

    /// Activates an app by pid, used as a fallback when the original window is unavailable.
    @MainActor
    static func focus(pid: pid_t) {
        cancelPendingActivation()
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else { return }
        activate(app: runningApp)
    }

    /// Close a window via AX. Returns true on success. Mirrors what the user would do
    /// by clicking the red close button — the app gets a chance to prompt for unsaved
    /// changes, etc. (We do NOT force-quit.)
    @discardableResult
    static func close(window: WindowInfo) -> Bool {
        perform(.close, window: window) == .accepted
    }

    /// Minimize a single window through its native AX attribute. This mirrors the yellow
    /// traffic-light button and leaves the app itself running and visible in Swiitch.
    @discardableResult
    static func minimize(window: WindowInfo) -> Bool {
        perform(.minimize, window: window) == .accepted
    }

    /// Press the target window's native green zoom button. Apps remain responsible for
    /// deciding whether that means zoom, restore, or their own standard window behavior.
    @discardableResult
    static func zoom(window: WindowInfo) -> Bool {
        perform(.zoom, window: window) == .accepted
    }

    /// Hide every window of the app via `NSRunningApplication.hide()`. Like ⌘H from the
    /// Finder. Returns false only if the pid is gone.
    @discardableResult
    static func hide(pid: pid_t) -> Bool {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else { return false }
        return runningApp.hide()
    }

    /// Injection isolates the permission/identity/capability gates from native side effects.
    struct ActionDependencies {
        var trusted: () -> Bool = { AXIsProcessTrusted() }
        var present: (WindowInfo) -> Bool = { isWindowPresent($0) }
        var resolve: (WindowInfo) -> AXUIElement? = { windowElement(for: $0, purpose: .windowAction) }
        var availability: (AXUIElement, WindowAction) -> WindowActionAvailability = actionAvailability
        var send: (AXUIElement, WindowAction) -> AXError = sendAction
    }

    static func perform(_ action: WindowAction, window: WindowInfo,
                        dependencies: ActionDependencies = .init()) -> WindowActionResult {
        guard dependencies.trusted() else { return .permissionRequired }
        guard dependencies.present(window) else { return .windowGone }
        guard let target = dependencies.resolve(window) else { return .unresolved }
        switch dependencies.availability(target, action) {
        case .unsupported: return .unsupported
        case .disabled: return .disabled
        case .available, .unknown: break
        }
        // Recheck after AX resolution; windows can close while the bridge is responding.
        guard dependencies.present(window) else { return .windowGone }
        return result(for: dependencies.send(target, action))
    }

    static func result(for error: AXError) -> WindowActionResult {
        switch error {
        case .success: .accepted
        case .apiDisabled: .permissionRequired
        case .attributeUnsupported, .actionUnsupported, .notImplemented: .unsupported
        case .invalidUIElement: .windowGone
        default: .failed
        }
    }

    /// Called only by bounded, demand-driven background work, never from a view body.
    static func capabilities(for window: WindowInfo) -> WindowActionCapabilities {
        guard AXIsProcessTrusted(), isWindowPresent(window),
              let target = windowElement(for: window, purpose: .windowAction) else { return .init() }
        var capabilities = WindowActionCapabilities()
        for action in WindowAction.allCases {
            guard !Task.isCancelled else { break }
            capabilities[action] = actionAvailability(target, action)
        }
        return capabilities
    }

    private static func actionAvailability(_ target: AXUIElement, _ action: WindowAction) -> WindowActionAvailability {
        if action == .minimize {
            var settable = DarwinBoolean(false)
            let error = AXUIElementIsAttributeSettable(target, kAXMinimizedAttribute as CFString, &settable)
            if error == .attributeUnsupported { return .unsupported }
            guard error == .success else { return .unknown }
            guard settable.boolValue else { return .disabled }
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute as CFString, &value) == .success,
               value as? Bool == true { return .disabled }
            return .available
        }
        let (error, button) = actionButton(target, action)
        if error == .attributeUnsupported || error == .noValue { return .unsupported }
        guard error == .success, let button else { return .unknown }
        var enabled: AnyObject?
        if AXUIElementCopyAttributeValue(button, kAXEnabledAttribute as CFString, &enabled) == .success,
           enabled as? Bool == false { return .disabled }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(button, &actions) == .success,
              let names = actions as? [String] else { return .unknown }
        return names.contains(kAXPressAction) ? .available : .unsupported
    }

    private static func actionButton(_ target: AXUIElement, _ action: WindowAction) -> (AXError, AXUIElement?) {
        var value: AnyObject?
        let attribute = action == .close ? kAXCloseButtonAttribute : kAXZoomButtonAttribute
        let error = AXUIElementCopyAttributeValue(target, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (error, nil) }
        let button = value as! AXUIElement
        AXUIElementSetMessagingTimeout(button, 0.015)
        return (.success, button)
    }

    private static func sendAction(_ target: AXUIElement, _ action: WindowAction) -> AXError {
        if action == .minimize {
            return AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
        let (error, button) = actionButton(target, action)
        guard let button else { return error == .success ? .failure : error }
        return AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private static func windowElement(for window: WindowInfo, purpose: MatchingPurpose) -> AXUIElement? {
        if purpose == .windowAction { return actionWindowElement(for: window) }
        let windows = AXPrivate.windows(forPID: window.pid)
        guard !windows.isEmpty else { return nil }

        let candidates = windows.map {
            CandidateMetadata(
                windowID: AXPrivate.windowID(for: $0),
                title: purpose == .restore ? "" : axTitle(for: $0),
                bounds: purpose == .restore ? nil : axBounds(for: $0)
            )
        }
        guard let index = matchingCandidateIndex(for: window, candidates: candidates, purpose: purpose) else {
            return nil
        }
        return windows[index]
    }

    /// Exact IDs are checked before optional metadata, within a small messaging budget.
    /// A missing/slow bridge still fails closed; controls never fall back to another ID.
    private static func actionWindowElement(for window: WindowInfo) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        guard let windows = AXPrivate.availableWindows(forPID: window.pid, timeout: 0.03) else { return nil }
        var unresolved: [AXUIElement] = []
        for element in windows {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.015)
            let id = AXPrivate.windowID(for: element)
            if id == window.id { return element }
            if id == nil { unresolved.append(element) }
        }
        var metadata: [CandidateMetadata] = []
        for element in unresolved {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            metadata.append(.init(windowID: nil, title: axTitle(for: element), bounds: axBounds(for: element)))
        }
        guard let index = matchingCandidateIndex(for: window, candidates: metadata, purpose: .windowAction) else { return nil }
        return unresolved[index]
    }

    /// Exact IDs remain authoritative. Controls require a unique title AND bounds match
    /// with an unavailable ID; a known different ID must never receive a window action.
    /// Focus alone retains the permissive fallback for incomplete accessibility bridges.
    static func matchingCandidateIndex(
        for target: WindowInfo,
        candidates: [CandidateMetadata],
        purpose: MatchingPurpose = .focus
    ) -> Int? {
        if let exact = candidates.firstIndex(where: { $0.windowID == target.id }) {
            return exact
        }
        if purpose == .restore { return nil }
        let targetTitle = normalizedTitle(target.title)
        if purpose == .windowAction {
            guard !targetTitle.isEmpty else { return nil }
            let matches = candidates.indices.filter { index in
                let candidate = candidates[index]
                guard candidate.windowID == nil,
                      normalizedTitle(candidate.title) == targetTitle,
                      let bounds = candidate.bounds else { return false }
                return approximatelyEqual(bounds, target.bounds)
            }
            return matches.count == 1 ? matches[0] : nil
        }
        if candidates.count == 1 {
            return 0
        }

        guard !targetTitle.isEmpty else { return nil }
        let titleMatches = candidates.indices.filter {
            normalizedTitle(candidates[$0].title) == targetTitle
        }
        if titleMatches.count == 1 {
            return titleMatches[0]
        }

        let boundsMatches = titleMatches.filter { index in
            guard let bounds = candidates[index].bounds else { return false }
            return approximatelyEqual(bounds, target.bounds)
        }
        return boundsMatches.count == 1 ? boundsMatches[0] : nil
    }

    @discardableResult
    private static func raise(window: WindowInfo, purpose: MatchingPurpose = .focus) -> Bool {
        // A one-window fallback is unambiguous. Never raise the first of several AX
        // windows merely because Chromium supplied mismatched IDs; that can focus the
        // wrong tab/window after a deliberate selection.
        guard let match = windowElement(for: window, purpose: purpose) else { return false }

        // Unminiaturize if needed.
        var minimized: AnyObject?
        if AXUIElementCopyAttributeValue(match, kAXMinimizedAttribute as CFString, &minimized) == .success,
           let isMin = minimized as? Bool, isMin {
            AXUIElementSetAttributeValue(match, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }

        let main = AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, true as CFTypeRef)
        let focused = AXUIElementSetAttributeValue(match, kAXFocusedAttribute as CFString, true as CFTypeRef)
        let raised = AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        if purpose == .restore { return main == .success || focused == .success || raised == .success }
        return true
    }

    private static func axTitle(for element: AXUIElement) -> String {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private static func axBounds(for element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 8
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    @MainActor
    private static func activate(app: NSRunningApplication, window: WindowInfo? = nil) {
        // On macOS 14+, `NSRunningApplication.activate()` from an `.accessory` (LSUIElement)
        // app is frequently denied for cross-process activation. Avoiding the workaround
        // of toggling our own activation policy (which leaks phantom Dock icons under
        // SwiftUI + `MenuBarExtra`), we use the Accessibility API instead: setting
        // `kAXFrontmostAttribute = true` on the target app's AX element forces it frontmost
        // when we hold Accessibility permission.
        let pid = app.processIdentifier
        let originalFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axApp, kAXRaiseAction as CFString)

        // Belt-and-suspenders: also call `activate()`. On macOS pre-14 this is the only
        // thing that works; on macOS 14+ it's a no-op when AX already brought us forward.
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        // Some applications ignore both AX activation and AppKit activation while rebuilding
        // their window bridge. Verify the outcome instead of maintaining an application list;
        // The fallback belongs only to the latest focus intent. Do not resurrect an exited
        // app/closed window or steal focus if the user has moved to a third application.
        activationRetry.schedule(ifNeeded: {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return !app.isTerminated
                && ActivationRetry.isPending(targetPID: pid, sourcePID: originalFrontmostPID, frontmostPID: frontmostPID)
                && (window.map { isWindowPresent($0) } ?? true)
        }, action: {
            _ = AXPrivate.windowServerActivate(pid: pid)
        })
    }
}
