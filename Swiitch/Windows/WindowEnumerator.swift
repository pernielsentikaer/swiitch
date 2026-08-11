import AppKit
import ApplicationServices

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let bounds: CGRect
    let isOnScreen: Bool

    var displayTitle: String {
        title.isEmpty ? "Untitled" : title
    }
}

struct AppEntry: Identifiable, Hashable {
    var id: pid_t { pid }
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let icon: NSImage?
    var windows: [WindowInfo]
}

struct EnumerateOptions {
    /// If false, only includes windows currently on-screen (`.optionOnScreenOnly`) — drops
    /// windows on other Spaces, minimized windows, etc.
    var includeOtherSpaces: Bool = true
    /// If true, only includes windows whose frames intersect the active screen
    /// (the screen containing the mouse cursor).
    var restrictToActiveScreen: Bool = false
}

enum WindowEnumerator {
    /// Returns one entry per running regular app that owns at least one switchable window.
    static func enumerate(focusTracker: FocusTracker, options: EnumerateOptions = .init()) -> [AppEntry] {
        let allListOption: CGWindowListOption = options.includeOtherSpaces
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]

        let onScreen = copyWindows(option: [.optionOnScreenOnly, .excludeDesktopElements])
        let all = copyWindows(option: allListOption)
        let onScreenIDs = Set(onScreen.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })

        let excludedBundleIDs = Set(Preferences.excludedBundleIDs)
        let regularApps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && !excludedBundleIDs.contains(app.bundleIdentifier ?? "")
        }
        let regularPIDs = Set(regularApps.map { $0.processIdentifier })

        let activeScreenCG: CGRect? = options.restrictToActiveScreen ? activeScreenCGFrame() : nil

        // Build raw window list, keyed by pid.
        var byPID: [pid_t: [WindowInfo]] = [:]
        for entry in all {
            guard
                let pidNum = entry[kCGWindowOwnerPID as String] as? pid_t,
                regularPIDs.contains(pidNum),
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0,
                let wid = entry[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                bounds.width >= 80, bounds.height >= 60
            else { continue }

            if let screen = activeScreenCG, !screen.intersects(bounds) { continue }

            let title = entry[kCGWindowName as String] as? String ?? ""
            let info = WindowInfo(
                id: wid,
                pid: pidNum,
                title: title,
                bounds: bounds,
                isOnScreen: onScreenIDs.contains(wid)
            )
            byPID[pidNum, default: []].append(info)
        }

        // Drop ghost windows using AX: intersect with the windows AX actually reports for
        // the pid.
        //
        // Special case for Chromium-based apps (Chrome, Arc, Dia, Brave…): they use a
        // lazy-initialized AX layer that often returns AX windows whose internal
        // CGWindowIDs don't match what CGWindowList reports for the same NSWindow,
        // until AX "warms up." If we strictly intersect, those apps disappear from the
        // picker entirely. So: if AX reports windows but NONE of them match any
        // CGWindowList ID, treat AX as unreliable for that pid and trust CGWindowList.
        for (pid, windows) in byPID {
            let real = axWindowIDs(forPID: pid)
            guard !real.isEmpty else { continue }
            let filtered = windows.filter { real.contains($0.id) }
            if filtered.isEmpty && !windows.isEmpty {
                // AX returned windows but none agree with CGWindowList — almost
                // always a Chromium-style mismatched-id state. Skip the filter.
                continue
            }
            byPID[pid] = filtered
        }

        // Build entries.
        var entries: [AppEntry] = []
        for app in regularApps {
            let pid = app.processIdentifier
            let windows = byPID[pid] ?? []
            guard !windows.isEmpty else { continue }
            entries.append(AppEntry(
                pid: pid,
                bundleIdentifier: app.bundleIdentifier,
                name: app.localizedName ?? "Unknown",
                icon: app.icon,
                windows: windows
            ))
        }

        // Sort: pinned apps first (in pin order), then everything else by MRU rank,
        // ties broken alphabetically by name.
        let pinned = Preferences.pinnedBundleIDs
        entries.sort { lhs, rhs in
            let lPin = pinned.firstIndex(of: lhs.bundleIdentifier ?? "") ?? .max
            let rPin = pinned.firstIndex(of: rhs.bundleIdentifier ?? "") ?? .max
            if lPin != rPin { return lPin < rPin }

            let l = focusTracker.rank(for: lhs.bundleIdentifier)
            let r = focusTracker.rank(for: rhs.bundleIdentifier)
            if l != r { return l < r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return entries
    }

    private static func copyWindows(option: CGWindowListOption) -> [[String: Any]] {
        guard let raw = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw
    }

    private static func axWindowIDs(forPID pid: pid_t) -> Set<CGWindowID> {
        let app = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return [] }

        var result: Set<CGWindowID> = []
        for window in windows {
            if let wid = AXPrivate.windowID(for: window) {
                result.insert(wid)
            }
        }
        return result
    }

    /// Returns the frame of the screen selected by the user's `screenScope` preference,
    /// in CGWindow coordinates (origin top-left of the primary display).
    private static func activeScreenCGFrame() -> CGRect? {
        guard let screen = screenForCurrentScope() else { return nil }
        return convertToCGCoords(nsFrame: screen.frame)
    }

    /// Resolves the user's `screenScope` preference into an `NSScreen`.
    static func screenForCurrentScope() -> NSScreen? {
        let raw = UserDefaults.standard.string(forKey: Preferences.Key.screenScope)
            ?? Preferences.ScreenScope.mousePointer.rawValue
        switch Preferences.ScreenScope(rawValue: raw) ?? .mousePointer {
        case .mousePointer:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main
        case .activeWindow:
            // The screen of the frontmost app's key window. NSApp.keyWindow is *our*
            // app, so use NSWorkspace + AX to find the foreign frontmost window.
            if let frontmost = NSWorkspace.shared.frontmostApplication {
                let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
                var windowsValue: AnyObject?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                   let axWindows = windowsValue as? [AXUIElement],
                   let first = axWindows.first {
                    var posValue: AnyObject?
                    if AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &posValue) == .success,
                       CFGetTypeID(posValue!) == AXValueGetTypeID() {
                        var pos = CGPoint.zero
                        // swiftlint:disable:next force_cast
                        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
                        // pos is in CGWindow coords. Find the screen that contains it.
                        if let screen = NSScreen.screens.first(where: {
                            convertToCGCoords(nsFrame: $0.frame).contains(pos)
                        }) {
                            return screen
                        }
                    }
                }
            }
            return NSScreen.main
        case .main:
            return NSScreen.main
        }
    }

    private static func convertToCGCoords(nsFrame: CGRect) -> CGRect {
        // CGWindow coords: (0,0) is top-left of the primary display.
        // NSScreen coords: (0,0) is bottom-left of the primary display.
        guard let primary = NSScreen.screens.first else { return nsFrame }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: nsFrame.minX,
            y: primaryHeight - nsFrame.maxY,
            width: nsFrame.width,
            height: nsFrame.height
        )
    }
}
