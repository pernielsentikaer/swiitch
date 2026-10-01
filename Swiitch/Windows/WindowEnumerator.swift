import AppKit
import ApplicationServices

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let bounds: CGRect
    let isOnScreen: Bool
    /// nil means Accessibility could not confirm the state; it is not evidence of minimization.
    var isMinimized: Bool? = nil

    /// Hash by stable identity. Synthesized equality still compares every snapshot
    /// field, including CGRect, which is not Hashable in the macOS 14 SDK.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(pid)
    }

    var displayTitle: String {
        title.isEmpty ? String(localized: "Untitled") : title
    }

    /// Where the user would find this window right now.
    func presence(appHidden: Bool) -> WindowPresence {
        if isMinimized == true { return .minimized }
        if appHidden { return .hidden }
        return isOnScreen ? .current : .otherSpace
    }
}

/// Why a switchable window is not in front of the user: minimized to the Dock, owned by a
/// hidden app (⌘H), or living on another Space (including another app's full-screen Space).
/// WindowServer's on-screen flag covers every display's current Space, so "other Space" is
/// simply a live window the server does not currently draw.
enum WindowPresence: Equatable {
    case current, minimized, hidden, otherSpace

    /// Short status under the title; nil for a window on the current Space.
    var label: String? {
        switch self {
        case .current: nil
        case .minimized: String(localized: "Minimized")
        case .hidden: String(localized: "Hidden")
        case .otherSpace: String(localized: "Other Space")
        }
    }

    /// Minimized and hidden windows have no live pixels on screen; their last preview is dimmed.
    var isOutOfSight: Bool { self == .minimized || self == .hidden }
}

struct AppEntry: Identifiable, Hashable {
    var id: pid_t { pid }
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
    let icon: NSImage?
    var windows: [WindowInfo]
    /// The app is hidden with ⌘H; every window of it is off screen until it is unhidden.
    var isHidden: Bool = false
}

struct EnumerateOptions {
    /// Explicit list mutations need a new collection, not the normal warm-opening cache.
    var forceRefresh: Bool = false
    /// Periodic keep-warm work (discovery timer, idle prewarm) rather than a user opening
    /// the picker. While the user has not used Swiitch for a while, such requests reuse a
    /// snapshot for longer instead of polling every app's Accessibility bridge.
    var isBackgroundRefresh: Bool = false
    /// If false, excludes offscreen windows, except confirmed minimized windows when enabled.
    var includeOtherSpaces: Bool = true
    /// Independent of Spaces. Unknown AX state is never treated as confirmed minimized.
    var includeMinimizedWindows: Bool = true
    /// If true, only includes windows whose frames intersect the active screen
    /// (the screen containing the mouse cursor).
    var restrictToActiveScreen: Bool = false
    /// Bundle identifiers omitted before any Accessibility or thumbnail work begins.
    var excludedBundleIDs: Set<String> = []

    func includes(_ window: WindowInfo) -> Bool {
        if window.isMinimized == true { return includeMinimizedWindows }
        return includeOtherSpaces || window.isOnScreen
    }
}

enum WindowEnumerator {
    enum FilterReason: String, CaseIterable {
        case orphanedHost, hiddenHost, decorativeSurface, duplicateFrame, launchPlaceholder, notPublishedByAX
        /// Published by Accessibility as something other than a standard window (a button, an
        /// untitled HUD or dialog) beside a real titled window of the same app.
        case accessibilityAuxiliary
    }
    struct ApplicationSnapshot {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let localizedName: String?
        let icon: NSImage?
        var isHidden: Bool = false
    }

    /// The last successful Accessibility read for one app. A momentarily slow or busy
    /// bridge (a scanner mid-scan, an Electron app rebuilding its tree) must not switch
    /// ghost-window filtering off for that app, so a failed read falls back to this for a
    /// bounded time. `observedWindowIDs` scopes the reuse: only windows that already
    /// existed at the read are judged by it; anything created since is always kept.
    struct AccessibilityMemory: Equatable {
        let windowIDs: Set<CGWindowID>
        let observedWindowIDs: Set<CGWindowID>
        let recordedAt: TimeInterval
    }

    /// How long a remembered Accessibility read may stand in for a failed one.
    static let accessibilityMemoryLifetime: TimeInterval = 60

    /// AppKit metadata is snapshotted on the main actor; WindowServer/Accessibility
    /// collection runs independently and never reads the mutable focus tracker.
    struct Context {
        let applications: [ApplicationSnapshot]
        let options: EnumerateOptions
        let screenFrame: CGRect?
        /// Carried over from the previous collection by `WindowDiscovery`.
        var accessibilityMemory: [pid_t: AccessibilityMemory] = [:]
    }

    struct Collection {
        var apps: [AppEntry]
        let duration: TimeInterval
        let candidateCount: Int
        let filteredCount: Int
        /// Apps whose Accessibility read failed this round.
        let unavailableAXCount: Int
        /// Of those, apps that could still be filtered from a recent successful read.
        var reusedAXCount: Int = 0
        var filterReasons: [FilterReason: Int] = [:]
        /// Successful reads (fresh or still-valid carried ones) for the next collection.
        var accessibilityMemory: [pid_t: AccessibilityMemory] = [:]
    }

    @MainActor static func context(options: EnumerateOptions) -> Context {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !options.excludedBundleIDs.contains($0.bundleIdentifier ?? "")
        }.map {
            ApplicationSnapshot(processIdentifier: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier,
                                localizedName: $0.localizedName, icon: $0.icon, isHidden: $0.isHidden)
        }
        return Context(applications: applications, options: options,
                       screenFrame: options.restrictToActiveScreen ? activeScreenCGFrame() : nil)
    }

    /// Returns one entry per running regular app that owns at least one switchable window.
    /// Synchronous diagnostic entry point. Production uses WindowDiscovery's background cache.
    @MainActor static func enumerate(focusTracker: FocusTracker, options: EnumerateOptions = .init()) -> [AppEntry] {
        ordered(collect(context: context(options: options)).apps, focusTracker: focusTracker)
    }

    static func collect(context: Context, metadataBudget: TimeInterval = 0.6) -> Collection {
        let started = ProcessInfo.processInfo.systemUptime
        let options = context.options
        // One WindowServer pass: the complete list carries `kCGWindowIsOnscreen`, so a
        // second `.optionOnScreenOnly` copy would only duplicate work every collection.
        // Discover everything first, filter afterward: minimized windows are off-screen.
        let all = copyWindows(option: [.optionAll, .excludeDesktopElements])

        let regularApps = context.applications
        let regularPIDs = Set(regularApps.map { $0.processIdentifier })

        let activeScreenCG = context.screenFrame

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
                isOnScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) == true
            )
            byPID[pidNum, default: []].append(info)
        }

        // Prune high-confidence WindowServer host/utility surfaces, then prefer the remaining
        // windows published through Accessibility. No application identity is involved:
        // the same classifier applies to every process and to apps we have never seen before.
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let candidateCount = byPID.values.reduce(0) { $0 + $1.count }
        var unavailableAXCount = 0
        var reusedAXCount = 0
        var filterReasons: [FilterReason: Int] = [:]
        var metadataByPID: [pid_t: AXMetadata] = [:]
        // Keep only memories that are still fresh and belong to apps that still have windows.
        var memory = context.accessibilityMemory.filter {
            started - $0.value.recordedAt < accessibilityMemoryLifetime && byPID[$0.key] != nil
        }
        // Prioritize every app's window IDs before optional metadata (titles, minimized
        // state). Otherwise one slow window could consume the budget needed to reject
        // another app's helper surfaces.
        for (pid, windows) in byPID {
            // One slow application cannot impose its timeout on every later application.
            // Unknown metadata remains unknown, never a confirmed empty window list.
            let withinBudget = ProcessInfo.processInfo.systemUptime - started < metadataBudget
            let metadata = withinBudget && !Task.isCancelled
                ? axMetadata(forPID: pid, offscreenIDs: Set(windows.filter { !$0.isOnScreen }.map(\.id)),
                             untitledIDs: Set(windows.filter { $0.title.isEmpty }.map(\.id)),
                             deadline: started + metadataBudget) : nil
            metadataByPID[pid] = metadata
            if let metadata, !metadata.ids.isEmpty {
                memory[pid] = AccessibilityMemory(windowIDs: metadata.ids,
                                                  observedWindowIDs: Set(windows.map(\.id)),
                                                  recordedAt: started)
            } else if metadata == nil {
                unavailableAXCount += 1
            }
        }
        for (pid, windows) in byPID {
            let app = regularApps.first(where: { $0.processIdentifier == pid })
            let metadata = metadataByPID[pid]
            let deadline = started + metadataBudget
            let minimized = minimizedStates(in: metadata?.offscreen ?? [], deadline: deadline)
            let titles = accessibilityTitles(for: metadata?.untitled ?? [], deadline: deadline)
            let kinds = accessibilityKinds(for: metadata?.untitled ?? [], deadline: deadline)
            let auxiliaryIDs = accessibilityAuxiliaryIDs(kinds: kinds, accessibilityTitledIDs: Set(titles.keys))
            let annotated = windows.map { window in
                var window = window
                // WindowServer omits `kCGWindowName` without Screen Recording permission.
                // Accessibility titles keep search and title-based matching working then.
                if window.title.isEmpty, let title = titles[window.id] {
                    window = WindowInfo(id: window.id, pid: window.pid, title: title,
                                        bounds: window.bounds, isOnScreen: window.isOnScreen)
                }
                window.isMinimized = window.isOnScreen ? false : minimized[window.id]
                return window
            }
            let evidence = accessibilityEvidence(fresh: metadata?.ids, memory: memory[pid])
            if evidence.reused { reusedAXCount += 1 }
            byPID[pid] = switchableWindows(
                annotated,
                applicationName: app?.localizedName ?? "",
                mainDisplayBounds: mainDisplayBounds,
                accessibilityWindowIDs: evidence.ids,
                accessibilityObservedWindowIDs: evidence.observed,
                accessibilityAuxiliaryIDs: auxiliaryIDs,
                onFilter: { reason, count in filterReasons[reason, default: 0] += count }
            )
        }

        // Build entries.
        var entries: [AppEntry] = []
        for app in regularApps {
            let pid = app.processIdentifier
            let windows = (byPID[pid] ?? []).filter { options.includes($0) }
            guard !windows.isEmpty else { continue }
            entries.append(AppEntry(
                pid: pid,
                bundleIdentifier: app.bundleIdentifier,
                name: app.localizedName ?? String(localized: "Unknown"),
                icon: app.icon,
                windows: windows,
                isHidden: app.isHidden
            ))
        }

        let remainingCount = entries.reduce(0) { $0 + $1.windows.count }
        return Collection(apps: entries, duration: ProcessInfo.processInfo.systemUptime - started,
                          candidateCount: candidateCount, filteredCount: candidateCount - remainingCount,
                          unavailableAXCount: unavailableAXCount, reusedAXCount: reusedAXCount,
                          filterReasons: filterReasons, accessibilityMemory: memory)
    }

    static func ordered(_ apps: [AppEntry], focusTracker: FocusTracker) -> [AppEntry] {
        var entries = apps
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

    private struct AXMetadata {
        var ids: Set<CGWindowID> = []
        var offscreen: [(CGWindowID, AXUIElement)] = []
        /// Windows whose WindowServer title was empty; their AX titles are read after every
        /// app's ID pass so optional metadata never starves identity checks.
        var untitled: [(CGWindowID, AXUIElement)] = []
    }

    /// Resolve IDs before optional state reads so a slow minimized-state lookup cannot
    /// weaken ghost filtering. Both passes share the existing bounded metadata budget.
    private static func axMetadata(forPID pid: pid_t, offscreenIDs: Set<CGWindowID>,
                                   untitledIDs: Set<CGWindowID> = [],
                                   deadline: TimeInterval) -> AXMetadata? {
        guard let windows = AXPrivate.availableWindows(forPID: pid, timeout: 0.03) else { return nil }
        guard !windows.isEmpty else { return AXMetadata() }

        var result = AXMetadata()
        for window in windows {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(window, 0.01)
            if let wid = AXPrivate.windowID(for: window) {
                result.ids.insert(wid)
                if offscreenIDs.contains(wid) { result.offscreen.append((wid, window)) }
                if untitledIDs.contains(wid) { result.untitled.append((wid, window)) }
            }
        }
        guard !result.ids.isEmpty else { return nil }
        return result
    }

    /// What an app's Accessibility bridge says a window *is*. Read only for windows that
    /// WindowServer reports without a title, after every app's identity pass.
    struct AccessibilityKind: Equatable {
        let role: String
        let subrole: String
    }

    private static func accessibilityKinds(for untitled: [(CGWindowID, AXUIElement)],
                                           deadline: TimeInterval) -> [CGWindowID: AccessibilityKind] {
        var result: [CGWindowID: AccessibilityKind] = [:]
        for (id, window) in untitled {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { break }
            var role: AnyObject?
            var subrole: AnyObject?
            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
                  let role = role as? String else { continue }
            _ = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            result[id] = AccessibilityKind(role: role, subrole: subrole as? String ?? "")
        }
        return result
    }

    /// Windows whose Accessibility description says they are not user windows at all: an
    /// element that is not a window (CleanMyMac exposes its animated scan button as one), or
    /// an untitled non-standard surface (HUD, badge, floating panel, unnamed dialog). An
    /// AXWindow that gained a title through Accessibility is never auxiliary. Non-window
    /// roles remain auxiliary even if the element has an Accessibility title.
    static func accessibilityAuxiliaryIDs(
        kinds: [CGWindowID: AccessibilityKind],
        accessibilityTitledIDs: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        let auxiliarySubroles: Set<String> = [
            kAXUnknownSubrole, kAXDialogSubrole, kAXSystemDialogSubrole,
            kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole,
        ]
        return Set(kinds.compactMap { (id, kind) -> CGWindowID? in
            if kind.role != kAXWindowRole { return id }
            guard !accessibilityTitledIDs.contains(id) else { return nil }
            return auxiliarySubroles.contains(kind.subrole) ? id : nil
        })
    }

    /// Drops auxiliary surfaces only beside a genuine anchor: a titled, non-auxiliary,
    /// at-least-as-large sibling. A sole unusual window still represents its app, and a
    /// minimized window is never judged by its overlay status.
    static func windowsRemovingAccessibilityAuxiliaries(
        _ windows: [WindowInfo],
        auxiliaryIDs: Set<CGWindowID>,
        onFilter: ((FilterReason, Int) -> Void)? = nil
    ) -> [WindowInfo] {
        guard !auxiliaryIDs.isEmpty, windows.count > 1 else { return windows }
        let anchors = windows.filter { !auxiliaryIDs.contains($0.id) && !normalized($0.title).isEmpty }
        guard !anchors.isEmpty else { return windows }
        func area(_ window: WindowInfo) -> CGFloat { window.bounds.width * window.bounds.height }
        let removed = Set(windows.compactMap { window -> CGWindowID? in
            guard auxiliaryIDs.contains(window.id), window.isMinimized != true else { return nil }
            return anchors.contains { area($0) >= area(window) } ? window.id : nil
        })
        guard !removed.isEmpty, removed.count < windows.count else { return windows }
        onFilter?(.accessibilityAuxiliary, removed.count)
        return windows.filter { !removed.contains($0.id) }
    }

    private static func accessibilityTitles(for untitled: [(CGWindowID, AXUIElement)],
                                            deadline: TimeInterval) -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]
        for (id, window) in untitled {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { break }
            if let title = AXPrivate.title(for: window) { result[id] = title }
        }
        return result
    }

    /// What to judge an app's windows against: a fresh read when there is one, otherwise a
    /// recent remembered read scoped to the windows it observed. Fresh evidence always wins,
    /// including a confirmed-empty list, which memory never contains.
    static func accessibilityEvidence(
        fresh: Set<CGWindowID>?,
        memory: AccessibilityMemory?
    ) -> (ids: Set<CGWindowID>?, observed: Set<CGWindowID>?, reused: Bool) {
        if let fresh { return (fresh, nil, false) }
        guard let memory, !memory.windowIDs.isEmpty else { return (nil, nil, false) }
        return (memory.windowIDs, memory.observedWindowIDs, true)
    }

    private static func minimizedStates(in offscreen: [(CGWindowID, AXUIElement)],
                                        deadline: TimeInterval) -> [CGWindowID: Bool] {
        var result: [CGWindowID: Bool] = [:]
        for (id, window) in offscreen {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { break }
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == CFBooleanGetTypeID() {
                result[id] = (value as! Bool)
            }
        }
        return result
    }

    /// `observedWindowIDs` is set when `axWindowIDs` comes from a remembered read: only
    /// windows that existed then, were not published then, and are still off-screen now are
    /// dropped. A window created since, or one visible on screen right now, is never hidden
    /// on the strength of an old read.
    static func windowsMatchingAccessibility(
        _ windows: [WindowInfo],
        axWindowIDs: Set<CGWindowID>?,
        observedWindowIDs: Set<CGWindowID>? = nil
    ) -> [WindowInfo] {
        guard let axWindowIDs, !axWindowIDs.isEmpty else { return windows }
        let filtered = windows.filter { window in
            if axWindowIDs.contains(window.id) { return true }
            guard let observedWindowIDs else { return false }
            return !observedWindowIDs.contains(window.id) || window.isOnScreen
        }
        // A non-empty AX list with zero CG matches is a known transient state while an app's
        // accessibility bridge rebuilds. Treat that as unavailable metadata for every app,
        // rather than maintaining a bundle-ID allowlist for particular frameworks.
        return filtered.isEmpty ? windows : filtered
    }

    static func switchableWindows(
        _ windows: [WindowInfo],
        applicationName: String,
        mainDisplayBounds: CGRect,
        accessibilityWindowIDs: Set<CGWindowID>?,
        accessibilityObservedWindowIDs: Set<CGWindowID>? = nil,
        accessibilityAuxiliaryIDs: Set<CGWindowID> = [],
        onFilter: ((FilterReason, Int) -> Void)? = nil
    ) -> [WindowInfo] {
        // A framework can retain its hidden 500x500 host after the last document closes.
        // The sibling-based filter below deliberately keeps a sole unusual window, but
        // a confirmed empty AX list lets us drop this known host even without a sibling.
        // Never infer this from missing titles, failed captures, or an unavailable AX bridge.
        let candidates = accessibilityWindowIDs?.isEmpty == true
            ? windows.filter { !isDefaultHostSurface($0, mainDisplayBounds: mainDisplayBounds) }
            : windows
        onFilter?(.orphanedHost, windows.count - candidates.count)
        let structurallyPruned = windowsRemovingNonUserSurfaces(
            candidates,
            applicationName: applicationName,
            mainDisplayBounds: mainDisplayBounds,
            onFilter: onFilter
        )
        let withoutAuxiliaries = windowsRemovingAccessibilityAuxiliaries(
            structurallyPruned,
            auxiliaryIDs: accessibilityAuxiliaryIDs,
            onFilter: onFilter
        )
        let matched = windowsMatchingAccessibility(
            withoutAuxiliaries,
            axWindowIDs: accessibilityWindowIDs,
            observedWindowIDs: accessibilityObservedWindowIDs
        )
        onFilter?(.notPublishedByAX, withoutAuxiliaries.count - matched.count)
        return matched
    }

    /// Removes high-confidence non-user surfaces using only properties of the process's window
    /// set. The rules describe framework behavior rather than applications:
    /// - hidden default 500x500 hosts parked at the display edge;
    /// - untitled decorative wrappers and extreme-aspect strips around a real window;
    /// - untitled duplicates of a titled window with the same frame;
    /// - hidden default-size launch placeholders named only after their owning application.
    ///
    /// Every rule requires a genuine sibling, so an unusual sole window is never enough to make
    /// an application disappear from the switcher.
    static func windowsRemovingNonUserSurfaces(
        _ windows: [WindowInfo],
        applicationName: String,
        mainDisplayBounds: CGRect,
        onFilter: ((FilterReason, Int) -> Void)? = nil
    ) -> [WindowInfo] {
        guard windows.count > 1 else { return windows }

        var remaining = windows

        let hostIDs = Set(remaining.compactMap { window in
            isDefaultHostSurface(window, mainDisplayBounds: mainDisplayBounds)
                ? window.id
                : nil
        })
        if !hostIDs.isEmpty, hostIDs.count < remaining.count {
            onFilter?(.hiddenHost, hostIDs.count)
            remaining.removeAll { hostIDs.contains($0.id) }
        }

        let decorativeIDs = Set(remaining.compactMap { window -> CGWindowID? in
            guard window.isMinimized != true, normalized(window.title).isEmpty else { return nil }
            let isWrapper = remaining.contains { sibling in
                sibling.id != window.id
                    && !normalized(sibling.title).isEmpty
                    && isCenteredDecorativeWrapper(window.bounds, around: sibling.bounds)
            }
            return isWrapper || isExtremeAspectStrip(window.bounds) ? window.id : nil
        })
        if !decorativeIDs.isEmpty, decorativeIDs.count < remaining.count {
            onFilter?(.decorativeSurface, decorativeIDs.count)
            remaining.removeAll { decorativeIDs.contains($0.id) }
        }

        let untitledDuplicateIDs = Set(remaining.compactMap { window -> CGWindowID? in
            guard window.isMinimized != true, normalized(window.title).isEmpty else { return nil }
            let hasTitledTwin = remaining.contains { sibling in
                sibling.id != window.id
                    && !normalized(sibling.title).isEmpty
                    && approximatelyEqual(sibling.bounds, window.bounds)
            }
            return hasTitledTwin ? window.id : nil
        })
        if !untitledDuplicateIDs.isEmpty, untitledDuplicateIDs.count < remaining.count {
            onFilter?(.duplicateFrame, untitledDuplicateIDs.count)
            remaining.removeAll { untitledDuplicateIDs.contains($0.id) }
        }

        let placeholderIDs = Set(remaining.compactMap { window in
            isDefaultLaunchPlaceholder(
                window,
                applicationName: applicationName,
                mainDisplayBounds: mainDisplayBounds
            ) ? window.id : nil
        })
        if !placeholderIDs.isEmpty, placeholderIDs.count < remaining.count {
            onFilter?(.launchPlaceholder, placeholderIDs.count)
            remaining.removeAll { placeholderIDs.contains($0.id) }
        }

        // Repeated small dimensions do not identify a utility: real notes/documents can
        // share a size, including off-screen or untitled ones. Leave those candidates
        // for Accessibility membership filtering instead of deleting them by geometry.
        return remaining
    }

    static func isDefaultHostSurface(
        _ window: WindowInfo,
        mainDisplayBounds: CGRect
    ) -> Bool {
        let normalizedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tolerance: CGFloat = 8
        return normalizedTitle.isEmpty
            && window.isMinimized != true
            && !window.isOnScreen
            && abs(window.bounds.width - 500) <= tolerance
            && abs(window.bounds.height - 500) <= tolerance
            && abs(window.bounds.minX - mainDisplayBounds.minX) <= tolerance
            && abs(window.bounds.maxY - mainDisplayBounds.maxY) <= tolerance
    }

    static func isDefaultLaunchPlaceholder(
        _ window: WindowInfo,
        applicationName: String,
        mainDisplayBounds: CGRect
    ) -> Bool {
        let tolerance: CGFloat = 8
        let title = normalized(window.title)
        let ownerName = normalized(applicationName)
        return !window.isOnScreen
            && window.isMinimized != true
            && !title.isEmpty
            && title == ownerName
            && abs(window.bounds.minX - mainDisplayBounds.minX) <= tolerance
            && abs(window.bounds.minY - mainDisplayBounds.minY) <= tolerance
            && abs(window.bounds.width - 800) <= tolerance
            && abs(window.bounds.height - 600) <= tolerance
    }

    static func isCenteredDecorativeWrapper(_ outer: CGRect, around inner: CGRect) -> Bool {
        let widthDelta = outer.width - inner.width
        let heightDelta = outer.height - inner.height
        return widthDelta >= 16
            && widthDelta <= 200
            && heightDelta >= 16
            && heightDelta <= 200
            && abs(outer.midX - inner.midX) <= 8
            && abs(outer.midY - inner.midY) <= 8
    }

    static func isExtremeAspectStrip(_ bounds: CGRect) -> Bool {
        let shorter = min(bounds.width, bounds.height)
        let longer = max(bounds.width, bounds.height)
        return shorter > 0 && shorter <= 160 && longer / shorter >= 6
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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

    /// Returns the frame of the screen selected by the user's `screenScope` preference,
    /// in CGWindow coordinates (origin top-left of the primary display).
    static func activeScreenCGFrame() -> CGRect? {
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
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               let frame = AXPrivate.focusedWindowFrame(forPID: frontmost.processIdentifier),
               let index = screenIndex(forFocusedFrame: frame, screens: NSScreen.screens.map {
                   convertToCGCoords(nsFrame: $0.frame)
               }) {
                return NSScreen.screens[index]
            }
            return NSScreen.main
        case .main:
            return NSScreen.main
        }
    }

    /// The display containing most of the focused window wins, even if the window's
    /// top-left corner is on a different screen. Invalid/off-desktop frames fall back.
    static func screenIndex(forFocusedFrame frame: CGRect, screens: [CGRect]) -> Int? {
        guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = frame.intersection(screen)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        return best?.index
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
