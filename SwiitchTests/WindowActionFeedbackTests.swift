import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class WindowActionFeedbackTests: XCTestCase {
    private let window = WindowInfo(id: 42, pid: 101, title: "Private document",
        bounds: CGRect(x: 100, y: 100, width: 600, height: 400), isOnScreen: true)

    func testNativeActionGatesRejectBeforeAnyMutation() {
        let element = AXUIElementCreateApplication(101)
        for expected: WindowActionResult in [.permissionRequired, .windowGone, .unresolved, .unsupported, .disabled] {
            var sends = 0
            var resolutions = 0
            let dependencies = WindowFocuser.ActionDependencies(
                trusted: { expected != .permissionRequired },
                present: { _ in expected != .windowGone },
                resolve: { _ in resolutions += 1; return expected == .unresolved ? nil : element },
                availability: { _, _ in expected == .unsupported ? .unsupported : .disabled },
                send: { _, _ in sends += 1; return .success }
            )
            XCTAssertEqual(WindowFocuser.perform(.close, window: window, dependencies: dependencies), expected)
            XCTAssertEqual(sends, 0)
            if expected == .permissionRequired || expected == .windowGone { XCTAssertEqual(resolutions, 0) }
        }
    }

    func testWindowDisappearingDuringResolutionCannotReceiveAction() {
        var checks = 0
        var sends = 0
        let dependencies = WindowFocuser.ActionDependencies(
            trusted: { true }, present: { _ in checks += 1; return checks == 1 },
            resolve: { _ in AXUIElementCreateApplication(101) }, availability: { _, _ in .available },
            send: { _, _ in sends += 1; return .success }
        )
        XCTAssertEqual(WindowFocuser.perform(.zoom, window: window, dependencies: dependencies), .windowGone)
        XCTAssertEqual(sends, 0)
    }

    func testUnknownMetadataDoesNotPermanentlyDisableWorkingActions() {
        let element = AXUIElementCreateApplication(101)
        var actions: [WindowAction] = []
        let dependencies = WindowFocuser.ActionDependencies(
            trusted: { true }, present: { _ in true }, resolve: { _ in element },
            availability: { _, _ in .unknown },
            send: { target, action in
                XCTAssertTrue(CFEqual(target, element))
                actions.append(action)
                return .success
            }
        )
        for action in WindowAction.allCases {
            XCTAssertEqual(WindowFocuser.perform(action, window: window, dependencies: dependencies), .accepted)
        }
        XCTAssertEqual(actions, WindowAction.allCases)
    }

    func testNativeErrorsHaveSpecificSafeFeedback() {
        XCTAssertEqual(WindowFocuser.result(for: .success), .accepted)
        XCTAssertEqual(WindowFocuser.result(for: .apiDisabled), .permissionRequired)
        XCTAssertEqual(WindowFocuser.result(for: .invalidUIElement), .windowGone)
        XCTAssertEqual(WindowFocuser.result(for: .actionUnsupported), .unsupported)
        XCTAssertEqual(WindowFocuser.result(for: .attributeUnsupported), .unsupported)
        XCTAssertEqual(WindowFocuser.result(for: .cannotComplete), .failed)
        for action in WindowAction.allCases {
            for result: WindowActionResult in [.permissionRequired, .windowGone, .unresolved, .unsupported, .disabled, .failed] {
                XCTAssertNotNil(result.message(for: action))
                XCTAssertFalse(result.message(for: action)!.contains(window.title))
            }
            XCTAssertNil(WindowActionResult.accepted.message(for: action))
        }
    }

    func testOnlyConfirmedUnavailableControlsAreDisabled() {
        XCTAssertTrue(WindowActionAvailability.unknown.canAttempt)
        XCTAssertTrue(WindowActionAvailability.available.canAttempt)
        XCTAssertFalse(WindowActionAvailability.unsupported.canAttempt)
        XCTAssertFalse(WindowActionAvailability.disabled.canAttempt)
        var capabilities = WindowActionCapabilities(close: .available, minimize: .unsupported, zoom: .disabled)
        XCTAssertEqual(capabilities[.close], .available)
        XCTAssertEqual(capabilities[.minimize], .unsupported)
        capabilities[.zoom] = .available
        XCTAssertEqual(capabilities.zoom, .available)
    }

    func testRejectedActionsExplainFailureWithoutChangingSelectionOrList() {
        let fixture = Fixture(result: .unsupported)
        fixture.model.arm(reverse: false)
        let ids = fixture.model.flatWindows.map(\.id)
        let selection = fixture.model.selectedFlatIndex
        XCTAssertFalse(fixture.model.minimizeWindow(id: 42))
        XCTAssertEqual(fixture.model.actionFeedback, WindowActionResult.unsupported.message(for: .minimize))
        XCTAssertEqual(fixture.model.windowCapabilities[42]?.minimize, .unsupported)
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), ids)
        XCTAssertEqual(fixture.model.selectedFlatIndex, selection)
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testSearchAndSuccessfulRetryClearFailureFeedback() {
        let fixture = Fixture(result: .failed)
        fixture.model.arm(reverse: false)
        XCTAssertFalse(fixture.model.zoomWindow(id: 42))
        XCTAssertNotNil(fixture.model.actionFeedback)
        fixture.model.appendFilter("Example")
        XCTAssertNil(fixture.model.actionFeedback)
        XCTAssertFalse(fixture.model.zoomWindow(id: 42))
        fixture.state.result = .accepted
        XCTAssertTrue(fixture.model.zoomWindow(id: 42))
        XCTAssertNil(fixture.model.actionFeedback)
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testKeyboardCloseAndHideFailuresAlsoExplainThemselves() {
        let fixture = Fixture(result: .permissionRequired)
        fixture.model.arm(reverse: false)
        fixture.model.closeSelected()
        XCTAssertEqual(fixture.model.actionFeedback, WindowActionResult.permissionRequired.message(for: .close))
        fixture.model.hideSelected()
        XCTAssertEqual(fixture.model.actionFeedback, Bundle(for: SwitcherModel.self).localizedString(
            forKey: "Couldn’t hide this app. Please try again.", value: nil, table: nil
        ))
        XCTAssertEqual(fixture.model.flatWindows.count, 1)
    }

    func testCancelledSessionDiscardsFeedbackAndLateCapabilities() async {
        let gate = DiscoveryGate()
        var calls = 0
        let fixture = Fixture(result: .failed, read: { _ in
            calls += 1
            await gate.wait()
            return .init(close: .unsupported)
        })
        fixture.model.arm(reverse: false)
        fixture.model.prepareWindowControls(id: 42)
        await eventually { calls == 1 }
        fixture.model.closeSelected()
        fixture.model.cancel()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(fixture.model.windowCapabilities.isEmpty)
        XCTAssertNil(fixture.model.actionFeedback)
    }

    func testCapabilityReadsAreDemandDrivenCoalescedAndCached() async {
        let gate = DiscoveryGate()
        var calls = 0
        let fixture = Fixture(read: { _ in
            calls += 1
            await gate.wait()
            return .init(close: .available, minimize: .unsupported)
        })
        fixture.model.prepareWindowControls(id: 42)
        XCTAssertEqual(calls, 0)
        fixture.model.arm(reverse: false)
        XCTAssertEqual(calls, 0, "Arming alone must not scan every window's controls")
        for _ in 0..<10 { fixture.model.prepareWindowControls(id: 42) }
        await eventually { calls == 1 }
        await gate.release()
        await eventually { fixture.model.windowCapabilities[42] != nil }
        fixture.model.prepareWindowControls(id: 42)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.model.windowCapabilities[42]?.minimize, .unsupported)
    }

    func testMutationInvalidatesAnOlderCapabilityRequest() async {
        let gate = DiscoveryGate()
        var calls = 0
        let fixture = Fixture(read: { _ in
            calls += 1
            if calls == 1 {
                await gate.wait()
                return .init(minimize: .available)
            }
            return .init(minimize: .disabled)
        })
        fixture.model.arm(reverse: false)
        fixture.model.prepareWindowControls(id: 42)
        await eventually { calls == 1 }
        XCTAssertTrue(fixture.model.minimizeWindow(id: 42))
        await eventually { fixture.model.windowCapabilities[42]?.minimize == .disabled }
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.model.windowCapabilities[42]?.minimize, .disabled)
    }

    func testUnknownReadDoesNotOverrideAnExplicitNativeRejection() async {
        var calls = 0
        let fixture = Fixture(result: .unsupported, read: { _ in calls += 1; return .init() })
        fixture.model.arm(reverse: false)
        XCTAssertFalse(fixture.model.minimizeWindow(id: 42))
        await eventually { calls == 1 }
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.model.windowCapabilities[42]?.minimize, .unsupported)
    }

    func testNewSessionDoesNotInheritCapabilitiesFromOldSession() async {
        let gate = DiscoveryGate()
        var calls = 0
        let fixture = Fixture(read: { _ in
            calls += 1
            if calls == 1 { await gate.wait(); return .init(close: .unsupported) }
            return .init(close: .available)
        })
        fixture.model.arm(reverse: false)
        fixture.model.prepareWindowControls(id: 42)
        await eventually { calls == 1 }
        fixture.model.cancel()
        fixture.model.arm(reverse: false)
        fixture.model.prepareWindowControls(id: 42)
        await eventually { fixture.model.windowCapabilities[42]?.close == .available }
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fixture.model.windowCapabilities[42]?.close, .available)
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for test state", file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        final class State { var result: WindowActionResult = .accepted }
        let state = State()
        let suite = "WindowActionFeedbackTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let model: SwitcherModel

        init(result: WindowActionResult = .accepted, read: ((WindowInfo) async -> WindowActionCapabilities)? = nil) {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set("windows", forKey: Preferences.Key.displayMode)
            defaults.set(0, forKey: Preferences.Key.switcherShowDelayMs)
            defaults.set(false, forKey: Preferences.Key.peekOnHover)
            state.result = result
            let state = self.state
            let window = WindowInfo(id: 42, pid: 101, title: "Example", bounds: .zero, isOnScreen: true)
            let app = AppEntry(pid: 101, bundleIdentifier: "example", name: "Example", icon: nil, windows: [window])
            model = SwitcherModel(focusTracker: FocusTracker(), defaults: defaults, dependencies: .init(
                enumerate: { _, _ in [app] }, focusApp: { _ in }, focusWindow: { _ in },
                closeWindow: { _ in false }, minimizeWindow: { _ in false }, zoomWindow: { _ in false },
                hideApp: { _ in false }, focusPID: { _ in }, frontmostPID: { 101 },
                frontmostBundleID: { "example" }, focusedWindowID: { _ in 42 },
                scheduleCloseReconciliation: { $0() }, readWindowCapabilities: read,
                performWindowAction: { _, _ in state.result }
            ))
        }

        deinit {
            // deinit is nonisolated; the fixture only ever dies on the main-actor test.
            MainActor.assumeIsolated { model.cancel() }
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
