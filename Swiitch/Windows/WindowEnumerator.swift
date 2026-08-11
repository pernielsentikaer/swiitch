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
    /// Bundle identifiers omitted before any Accessibility or thumbnail work begins.
    var excludedBundleIDs: Set<String> = []
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

        let regularApps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && !options.excludedBundleIDs.contains(app.bundleIdentifier ?? "")
        }
        let regularPIDs = Set(regularApps.map { $0.processIdentifier })
        let bundleIDByPID = Dictionary(uniqueKeysWithValues: regularApps.compactMap { app in
            app.bundleIdentifier.map { (app.processIdentifier, $0) }
        })

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
            if isKnownAuxiliaryWindow(
                bundleID: bundleIDByPID[pidNum],
                title: title,
                bounds: bounds
            ) {
                continue
            }
            let info = WindowInfo(
                id: wid,
                pid: pidNum,
                title: title,
                bounds: bounds,
                isOnScreen: onScreenIDs.contains(wid)
            )
            byPID[pidNum, default: []].append(info)
        }

        // Drop ghost windows using AX: intersect with the windows AX actually reports for the pid.
        // Chromium-family apps can expose a completely different set of AX window IDs while
        // their accessibility bridge warms up. Only in that known all-mismatch case do we keep
        // the already-filtered CGWindowList entries instead of making the app disappear.
        for (pid, windows) in byPID {
            let real = axWindowIDs(forPID: pid)
            guard !real.isEmpty else { continue }
            let filtered = windows.filter { real.contains($0.id) }
            let bundleID = regularApps.first(where: { $0.processIdentifier == pid })?.bundleIdentifier
            if filtered.isEmpty, !windows.isEmpty, isChromiumFamily(bundleID: bundleID) {
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

    static func isChromiumFamily(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        let prefixes = [
            "com.google.chrome",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "com.operasoftware.opera",
            "com.vivaldi.vivaldi",
            "company.thebrowser.browser",
            "company.thebrowser.dia",
        ]
        return prefixes.contains(where: bundleID.hasPrefix)
    }

    /// Some apps keep switcher-ineligible helper windows alive as ordinary layer-0 windows.
    /// Keep these rules deliberately narrow so normal application windows remain switchable.
    static func isKnownAuxiliaryWindow(
        bundleID: String?,
        title: String,
        bounds: CGRect
    ) -> Bool {
        let normalizedBundleID = bundleID?.lowercased() ?? ""
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let width = bounds.width
        let height = bounds.height

        // Warp's dedicated global-hotkey surface is an untitled compact square host even while
        // hidden, so it survives the generic size/layer checks and appears as a blank window.
        if normalizedBundleID.hasPrefix("dev.warp.warp") {
            guard normalizedTitle.isEmpty else { return false }
            let isCompact = width >= 320 && height >= 320 && width <= 640 && height <= 640
            let isApproximatelySquare = abs(width - height) <= 24
            return isCompact && isApproximatelySquare
        }

        // ChatGPT briefly creates two identically sized utility surfaces while Computer Use is
        // active. macOS exposes both through CGWindowList and Accessibility as regular windows,
        // although neither is a user document. Their compact geometry prevents a task/window
        // with the same title from being hidden.
        if normalizedBundleID == "com.openai.codex" {
            let computerUseTitles: Set<String> = ["computer use", "computer use controls"]
            let isComputerUseHelper = computerUseTitles.contains(normalizedTitle)
            let isCompactUtilitySurface = width >= 280 && width <= 420
                && height >= 240 && height <= 360
            return isComputerUseHelper && isCompactUtilitySurface
        }

        return false
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
