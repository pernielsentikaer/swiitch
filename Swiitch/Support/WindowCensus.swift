import AppKit
import ApplicationServices

/// A debugging dump of what WindowServer, Accessibility, and the Spaces system each say
/// about every window of every regular app, next to the switcher's own verdict. Unlike
/// `DiagnosticsReport` it names apps (bundle IDs) and window geometry, so it is a separate,
/// explicitly labelled action. It never includes window titles, only whether one exists.
enum WindowCensus {
    @MainActor
    static func render() async -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "?", name: $0.localizedName ?? "?") }
        // Judge with the same scope the picker uses, so KEPT/dropped matches what the user sees.
        let defaults = UserDefaults.standard
        let options = EnumerateOptions(
            includeOtherSpaces: defaults.bool(forKey: Preferences.Key.includeOtherSpaces),
            includeMinimizedWindows: Preferences.minimizedWindows(in: defaults) != .hide,
            restrictToActiveScreen: defaults.bool(forKey: Preferences.Key.restrictToActiveScreen),
            excludedBundleIDs: Set(Preferences.excludedBundleIDs)
        )
        let context = WindowEnumerator.context(options: options)
        let collection = await Task.detached { WindowEnumerator.collect(context: context) }.value
        let keptByPID = Dictionary(uniqueKeysWithValues: collection.apps.map { ($0.pid, Set($0.windows.map(\.id))) })

        let rows = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let rowsByPID = Dictionary(grouping: rows) { $0[kCGWindowOwnerPID as String] as? pid_t ?? -1 }

        var lines: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("Swiitch window census \(version) (\(build)), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("scope: otherSpaces=\(options.includeOtherSpaces) minimized=\(options.includeMinimizedWindows) "
            + "activeScreenOnly=\(options.restrictToActiveScreen) excluded=\(options.excludedBundleIDs.count)")
        lines.append("accessibility=\(AXIsProcessTrusted()) screenRecording=\(CGPreflightScreenCaptureAccess()) "
            + "windowIDSPI=\(AXPrivate.windowIDResolverAvailable) spacesSPI=\(AXPrivate.spacesResolverAvailable) "
            + "displays=\(NSScreen.screens.count)")
        lines.append("collection: apps=\(collection.apps.count) windows=\(collection.apps.reduce(0) { $0 + $1.windows.count }) "
            + "candidates=\(collection.candidateCount) axUnavailable=\(collection.unavailableAXCount) "
            + "axReused=\(collection.reusedAXCount) filters=\(collection.filterReasons.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ","))")

        for app in apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let cgRows = rowsByPID[app.pid] ?? []
            let axWindows = AXPrivate.availableWindows(forPID: app.pid, timeout: 0.1)
            var axByID: [CGWindowID: AXUIElement] = [:]
            var axUnresolved = 0
            for element in axWindows ?? [] {
                if let id = AXPrivate.windowID(for: element) { axByID[id] = element } else { axUnresolved += 1 }
            }
            let axSummary = axWindows.map { "\($0.count) (unresolved ids: \(axUnresolved))" } ?? "unavailable"
            lines.append("")
            lines.append("\(app.bundleID) pid=\(app.pid) cgWindows=\(cgRows.count) axWindows=\(axSummary) kept=\(keptByPID[app.pid]?.count ?? 0)")
            for row in cgRows {
                guard let id = row[kCGWindowNumber as String] as? CGWindowID else { continue }
                let layer = row[kCGWindowLayer as String] as? Int ?? -1
                let alpha = row[kCGWindowAlpha as String] as? Double ?? -1
                let onScreen = (row[kCGWindowIsOnscreen as String] as? Bool) == true
                let titled = !((row[kCGWindowName as String] as? String) ?? "").isEmpty
                let bounds = (row[kCGWindowBounds as String] as? [String: Any])
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
                let memory = row[kCGWindowMemoryUsage as String] as? Int ?? 0
                let store = row[kCGWindowStoreType as String] as? Int ?? -1
                let sharing = row[kCGWindowSharingState as String] as? Int ?? -1
                let spaces = AXPrivate.spaceIDs(forWindow: id).map { "\($0)" } ?? "n/a"
                var ax = "absent"
                if let element = axByID[id] {
                    ax = "role=\(attribute(element, kAXRoleAttribute))/\(attribute(element, kAXSubroleAttribute))"
                        + " minimized=\(attribute(element, kAXMinimizedAttribute))"
                        + " main=\(attribute(element, kAXMainAttribute)) focused=\(attribute(element, kAXFocusedAttribute))"
                        + " titled=\(AXPrivate.title(for: element) != nil)"
                }
                let verdict = keptByPID[app.pid]?.contains(id) == true ? "KEPT" : "dropped"
                lines.append("  \(verdict) window=\(id) layer=\(layer) alpha=\(alpha) onscreen=\(onScreen) titled=\(titled) "
                    + "size=\(Int(bounds.width))x\(Int(bounds.height)) origin=\(Int(bounds.minX)),\(Int(bounds.minY)) "
                    + "memory=\(memory) store=\(store) sharing=\(sharing) spaces=\(spaces) ax=\(ax)")
            }
            let orphanAX = axByID.keys.filter { id in !cgRows.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == id } }
            if !orphanAX.isEmpty {
                lines.append("  ax-only window ids (no WindowServer row): \(orphanAX.sorted())")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> String {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return "?" }
        if let bool = value as? Bool { return bool ? "yes" : "no" }
        if let string = value as? String { return string }
        return "\(type(of: value))"
    }
}
