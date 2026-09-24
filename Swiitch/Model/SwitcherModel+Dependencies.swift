import AppKit

extension SwitcherModel {
    /// External operations used by the state machine. Keeping these injectable lets the
    /// selection and filtering behavior run under unit tests without focusing real apps,
    /// enumerating the developer's desktop, or requesting Screen Recording permission.
    struct Dependencies {
        var enumerate: @MainActor (FocusTracker, EnumerateOptions) -> [AppEntry]
        var prepareSnapshot: ((EnumerateOptions) async -> Void)?
        var focusApp: @MainActor (AppEntry) -> Void
        var focusWindow: @MainActor (WindowInfo) -> Void
        var closeWindow: (WindowInfo) -> Bool
        var minimizeWindow: (WindowInfo) -> Bool
        var zoomWindow: (WindowInfo) -> Bool
        var hideApp: (pid_t) -> Bool
        var focusPID: @MainActor (pid_t) -> Void
        var restoreWindowFocus: @MainActor (pid_t, CGWindowID) -> Bool
        var frontmostPID: () -> pid_t?
        var frontmostBundleID: () -> String?
        var focusedWindowID: (pid_t) -> CGWindowID?
        var thumbnails: ((
            [CGWindowID],
            Bool,
            ThumbnailProgressHandler?
        ) async -> [CGWindowID: NSImage])?
        var cancelThumbnailCaptures: (() async -> Void)?
        var retainThumbnails: ((Set<CGWindowID>) async -> Void)?
        var invalidateThumbnail: ((CGWindowID) async -> Void)?
        var screenCaptureGranted: () -> Bool
        var setThumbnailCaptureAllowed: ((Bool) async -> Void)?
        var scheduleCloseReconciliation: (@escaping () -> Void) -> Void
        var readWindowCapabilities: ((WindowInfo) async -> WindowActionCapabilities)?
        var performWindowAction: ((WindowAction, WindowInfo) -> WindowActionResult)?
        var cancelPendingFocus: @MainActor () -> Void

        init(
            enumerate: @escaping @MainActor (FocusTracker, EnumerateOptions) -> [AppEntry],
            focusApp: @escaping @MainActor (AppEntry) -> Void,
            focusWindow: @escaping @MainActor (WindowInfo) -> Void,
            closeWindow: @escaping (WindowInfo) -> Bool,
            minimizeWindow: @escaping (WindowInfo) -> Bool = { WindowFocuser.minimize(window: $0) },
            zoomWindow: @escaping (WindowInfo) -> Bool = { WindowFocuser.zoom(window: $0) },
            hideApp: @escaping (pid_t) -> Bool,
            focusPID: @escaping @MainActor (pid_t) -> Void = { WindowFocuser.focus(pid: $0) },
            restoreWindowFocus: @escaping @MainActor (pid_t, CGWindowID) -> Bool = { _, _ in false },
            frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            focusedWindowID: @escaping (pid_t) -> CGWindowID? = { AXPrivate.focusedWindowID(forPID: $0) },
            thumbnails: ((
                [CGWindowID],
                Bool,
                ThumbnailProgressHandler?
            ) async -> [CGWindowID: NSImage])? = nil,
            cancelThumbnailCaptures: (() async -> Void)? = nil,
            retainThumbnails: ((Set<CGWindowID>) async -> Void)? = nil,
            invalidateThumbnail: ((CGWindowID) async -> Void)? = nil,
            screenCaptureGranted: @escaping () -> Bool = { true },
            setThumbnailCaptureAllowed: ((Bool) async -> Void)? = nil,
            scheduleCloseReconciliation: @escaping (@escaping () -> Void) -> Void = { action in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: action)
            },
            prepareSnapshot: ((EnumerateOptions) async -> Void)? = nil,
            readWindowCapabilities: ((WindowInfo) async -> WindowActionCapabilities)? = nil,
            performWindowAction: ((WindowAction, WindowInfo) -> WindowActionResult)? = nil,
            cancelPendingFocus: @escaping @MainActor () -> Void = {}
        ) {
            self.enumerate = enumerate
            self.prepareSnapshot = prepareSnapshot
            self.focusApp = focusApp
            self.focusWindow = focusWindow
            self.closeWindow = closeWindow
            self.minimizeWindow = minimizeWindow
            self.zoomWindow = zoomWindow
            self.hideApp = hideApp
            self.focusPID = focusPID
            self.restoreWindowFocus = restoreWindowFocus
            self.frontmostPID = frontmostPID
            self.frontmostBundleID = frontmostBundleID
            self.focusedWindowID = focusedWindowID
            self.thumbnails = thumbnails
            self.cancelThumbnailCaptures = cancelThumbnailCaptures
            self.retainThumbnails = retainThumbnails
            self.invalidateThumbnail = invalidateThumbnail
            self.screenCaptureGranted = screenCaptureGranted
            self.setThumbnailCaptureAllowed = setThumbnailCaptureAllowed
            self.scheduleCloseReconciliation = scheduleCloseReconciliation
            self.readWindowCapabilities = readWindowCapabilities
            self.performWindowAction = performWindowAction
            self.cancelPendingFocus = cancelPendingFocus
        }

        static let live = Dependencies(
            enumerate: { focusTracker, options in
                WindowDiscovery.shared.entries(focusTracker: focusTracker, options: options)
            },
            focusApp: { WindowFocuser.focus(app: $0) },
            focusWindow: { WindowFocuser.focus(window: $0) },
            closeWindow: { WindowFocuser.close(window: $0) },
            minimizeWindow: { WindowFocuser.minimize(window: $0) },
            zoomWindow: { WindowFocuser.zoom(window: $0) },
            hideApp: { WindowFocuser.hide(pid: $0) },
            focusPID: { WindowFocuser.focus(pid: $0) },
            restoreWindowFocus: { WindowFocuser.restoreFocus(pid: $0, windowID: $1) },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            focusedWindowID: { AXPrivate.focusedWindowID(forPID: $0) },
            thumbnails: { windowIDs, fresh, onUpdate in
                await WindowThumbnails.shared.images(
                    for: windowIDs,
                    fresh: fresh,
                    // Prewarming fills missing entries only; do not recapture every
                    // background window every four seconds when no picker is visible.
                    maximumAge: onUpdate == nil ? .infinity : 3,
                    onUpdate: onUpdate
                )
            },
            cancelThumbnailCaptures: {
                await WindowThumbnails.shared.cancelPendingCaptures()
            },
            retainThumbnails: { liveIDs in
                await WindowThumbnails.shared.retain(only: liveIDs)
            },
            invalidateThumbnail: { windowID in
                await WindowThumbnails.shared.invalidate(windowID)
            },
            screenCaptureGranted: { CGPreflightScreenCaptureAccess() },
            setThumbnailCaptureAllowed: { allowed in
                await WindowThumbnails.shared.setCaptureAllowed(allowed)
            },
            prepareSnapshot: { await WindowDiscovery.shared.prepare(options: $0) },
            readWindowCapabilities: { await WindowActionCapabilityReader.shared.read($0) },
            performWindowAction: { WindowFocuser.perform($0, window: $1) },
            cancelPendingFocus: { WindowFocuser.cancelPendingActivation() }
        )
    }
}
