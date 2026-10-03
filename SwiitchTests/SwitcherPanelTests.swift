import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class SwitcherPanelTests: XCTestCase {
    func testPickerSitsAboveFloatingWindowsWithoutTakingFocus() {
        let suite = "SwitcherPanelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SwitcherModel(focusTracker: FocusTracker(), defaults: defaults, dependencies: .init(
            enumerate: { _, _ in [] }, focusApp: { _ in }, focusWindow: { _ in },
            closeWindow: { _ in false }, hideApp: { _ in false }))
        let panel = SwitcherPanel(model: model)
        defer { panel.close() }
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue,
                             "Another app's floating palette must not draw over the picker")
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary), "Shown over full-screen apps")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.canBecomeKey, "The picker never steals focus from the app the user is in")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }
}
