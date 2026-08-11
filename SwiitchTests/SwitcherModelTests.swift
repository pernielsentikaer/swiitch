import AppKit
@testable import Swiitch
import XCTest

final class SwitcherModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "com.swiitch.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.set(0, forKey: Preferences.Key.switcherShowDelayMs)
        defaults.set(false, forKey: Preferences.Key.peekOnHover)
        defaults.set(true, forKey: Preferences.Key.showWindowPreviews)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testAppFilterUsesWindowTitlesAndKeepsAbsoluteSelection() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        let apps = sampleApps()
        var focusedPID: pid_t?
        let model = makeModel(apps: apps, focusApp: { focusedPID = $0.pid })

        model.arm(reverse: false)
        XCTAssertEqual(model.selectedAppIndex, 1)

        model.appendFilter("resume")

        XCTAssertEqual(model.filteredApps.map(\.name), ["Gamma"])
        XCTAssertEqual(model.selectedAppIndex, 2, "Filtered selection must remain an absolute apps index")

        model.commit()
        XCTAssertEqual(focusedPID, 103)
        XCTAssertFalse(model.isArmed)
    }

    func testFlatWindowFilterKeepsAbsoluteSelection() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let apps = sampleApps()
        var focusedWindowID: CGWindowID?
        let model = makeModel(apps: apps, focusWindow: { focusedWindowID = $0.id })

        model.arm(reverse: false)
        XCTAssertEqual(model.selectedFlatIndex, 1)

        model.appendFilter("resume")

        XCTAssertEqual(model.filteredFlatWindows.map(\.id), [3])
        XCTAssertEqual(model.selectedFlatIndex, 2, "Filtered selection must remain an absolute window index")

        model.commit()
        XCTAssertEqual(focusedWindowID, 3)
        XCTAssertFalse(model.isArmed)
    }

    func testCommitWithNoMatchesDismissesWithoutFocusingAnything() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        var focusedPIDs: [pid_t] = []
        let model = makeModel(apps: sampleApps(), focusApp: { focusedPIDs.append($0.pid) })

        model.arm(reverse: false)
        model.appendFilter("does not exist")
        XCTAssertTrue(model.filteredApps.isEmpty)

        model.commit()

        XCTAssertTrue(focusedPIDs.isEmpty)
        XCTAssertFalse(model.isArmed)
    }

    func testNoMatchCannotCloseOrHideAnInvisibleItem() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        var closedWindowIDs: [CGWindowID] = []
        var hiddenPIDs: [pid_t] = []
        let model = makeModel(
            apps: sampleApps(),
            closeWindow: {
                closedWindowIDs.append($0.id)
                return true
            },
            hideApp: {
                hiddenPIDs.append($0)
                return true
            }
        )

        model.arm(reverse: false)
        model.appendFilter("does not exist")
        model.closeSelected()
        model.hideSelected()

        XCTAssertTrue(closedWindowIDs.isEmpty)
        XCTAssertTrue(hiddenPIDs.isEmpty)
        XCTAssertEqual(model.apps.count, 3)
    }

    func testWindowListPreferenceControlsDrillInAndClearsTheAppFilter() {
        defaults.set(Preferences.DisplayMode.apps.rawValue, forKey: Preferences.Key.displayMode)
        defaults.set(false, forKey: Preferences.Key.showWindowPreviews)
        let apps = [
            makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "One")]),
            makeApp(
                pid: 102,
                name: "Beta",
                windows: [
                    makeWindow(id: 2, pid: 102, title: "Two"),
                    makeWindow(id: 3, pid: 102, title: "Three"),
                ]
            ),
        ]
        let model = makeModel(apps: apps)

        model.arm(reverse: false)
        model.appendFilter("Beta")
        model.enterWindowMode()
        XCTAssertEqual(model.mode, .apps)

        defaults.set(true, forKey: Preferences.Key.showWindowPreviews)
        model.enterWindowMode()

        XCTAssertEqual(model.mode, .windowsForApp)
        XCTAssertEqual(model.filterText, "")
    }

    func testFailedCloseKeepsTheWindowVisible() {
        defaults.set(Preferences.DisplayMode.windows.rawValue, forKey: Preferences.Key.displayMode)
        let model = makeModel(apps: sampleApps(), closeWindow: { _ in false })

        model.arm(reverse: false)
        let originalIDs = model.flatWindows.map(\.id)
        model.closeSelected()

        XCTAssertEqual(model.flatWindows.map(\.id), originalIDs)
    }

    private func makeModel(
        apps: [AppEntry],
        focusApp: @escaping (AppEntry) -> Void = { _ in },
        focusWindow: @escaping (WindowInfo) -> Void = { _ in },
        closeWindow: @escaping (WindowInfo) -> Bool = { _ in true },
        hideApp: @escaping (pid_t) -> Bool = { _ in true }
    ) -> SwitcherModel {
        let dependencies = SwitcherModel.Dependencies(
            enumerate: { _, _ in apps },
            focusApp: focusApp,
            focusWindow: focusWindow,
            closeWindow: closeWindow,
            hideApp: hideApp
        )
        return SwitcherModel(
            focusTracker: FocusTracker(),
            defaults: defaults,
            dependencies: dependencies
        )
    }

    private func sampleApps() -> [AppEntry] {
        [
            makeApp(pid: 101, name: "Alpha", windows: [makeWindow(id: 1, pid: 101, title: "Dashboard")]),
            makeApp(pid: 102, name: "Beta", windows: [makeWindow(id: 2, pid: 102, title: "Inbox")]),
            makeApp(pid: 103, name: "Gamma", windows: [makeWindow(id: 3, pid: 103, title: "Résumé 2026")]),
        ]
    }

    private func makeApp(pid: pid_t, name: String, windows: [WindowInfo]) -> AppEntry {
        AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.\(name.lowercased())",
            name: name,
            icon: nil,
            windows: windows
        )
    }

    private func makeWindow(id: CGWindowID, pid: pid_t, title: String) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid,
            title: title,
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true
        )
    }
}
