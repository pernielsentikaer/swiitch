import AppKit

/// Tracks app activation order so we can present apps in Most-Recently-Used order,
/// even when the user switches apps via the mouse / system shortcut instead of Swiitch.
final class FocusTracker {
    private(set) var mruByBundle: [String] = []
    private var observer: NSObjectProtocol?

    func start() {
        // Seed with current ordering.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var seen = Set<String>()
        var seed: [String] = []
        if let frontmost { seed.append(frontmost); seen.insert(frontmost) }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, !seen.contains(id) else { continue }
            seed.append(id)
            seen.insert(id)
        }
        mruByBundle = seed

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let self,
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                let id = app.bundleIdentifier
            else { return }
            self.bump(id)
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    func bump(_ bundleID: String) {
        mruByBundle.removeAll { $0 == bundleID }
        mruByBundle.insert(bundleID, at: 0)
    }

    /// Returns the MRU index for a bundle id, or Int.max if not seen.
    func rank(for bundleID: String?) -> Int {
        guard let bundleID, let index = mruByBundle.firstIndex(of: bundleID) else { return .max }
        return index
    }
}
