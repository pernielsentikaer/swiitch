import AppKit
import Carbon.HIToolbox
@testable import Swiitch
import XCTest

/// Exercises the actual input handler without installing an event tap or operating on
/// real apps. Settings and model side effects are isolated for every test.
@MainActor
final class HotkeyManagerTests: XCTestCase {
    private final class FocusLog {
        var windowIDs: [CGWindowID] = []
        var closedWindowIDs: [CGWindowID] = []
        var hiddenAppPIDs: [pid_t] = []
    }

    private final class Fixture {
        let suiteName = "com.swiitch.hotkey-tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let model: SwitcherModel
        let manager: HotkeyManager
        let recording = ShortcutRecordingSession()
        let focus = FocusLog()

        init(primary: CGEventFlags = .maskCommand, secondary: CGEventFlags = .maskAlternate,
             primaryKey: Int = kVK_Tab, shiftCycles: Bool = false, hasWindows: Bool = true,
             beforeEnumeration: @escaping () -> Void = {},
             prepareSnapshot: ((EnumerateOptions) async -> Void)? = nil) {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.register(defaults: [
                Preferences.Key.hotkeyKeyCode: primaryKey,
                Preferences.Key.hotkeyModifierFlags: Int(primary.rawValue),
                Preferences.Key.currentAppHotkeyEnabled: true,
                Preferences.Key.currentAppHotkeyKeyCode: kVK_Tab,
                Preferences.Key.currentAppHotkeyModifierFlags: Int(secondary.rawValue),
                Preferences.Key.shiftCyclesBackwards: shiftCycles,
                Preferences.Key.displayMode: Preferences.DisplayMode.windows.rawValue,
                Preferences.Key.switcherShowDelayMs: 0,
                Preferences.Key.peekOnHover: false,
            ])
            let windows = (1...3).map { id in
                WindowInfo(id: CGWindowID(id), pid: 101, title: "Document \(id)",
                           bounds: CGRect(x: 50, y: 50, width: 900, height: 700), isOnScreen: true)
            }
            let app = AppEntry(pid: 101, bundleIdentifier: "example.app", name: "Example", icon: nil, windows: windows)
            let focus = self.focus
            model = SwitcherModel(focusTracker: FocusTracker(), defaults: defaults, dependencies: .init(
                enumerate: { _, _ in
                    beforeEnumeration()
                    return hasWindows ? [app] : []
                },
                focusApp: { _ in }, focusWindow: { focus.windowIDs.append($0.id) },
                closeWindow: { focus.closedWindowIDs.append($0.id); return false },
                minimizeWindow: { _ in false }, zoomWindow: { _ in false },
                hideApp: { focus.hiddenAppPIDs.append($0); return false }, focusPID: { _ in },
                frontmostPID: { 101 }, frontmostBundleID: { "example.app" }, focusedWindowID: { _ in 1 },
                prepareSnapshot: prepareSnapshot
            ))
            manager = HotkeyManager(model: model, defaults: defaults, recording: recording)
        }

        deinit {
            manager.uninstall()
            defaults.removePersistentDomain(forName: suiteName)
        }

        @discardableResult
        func send(_ key: Int = kVK_Tab, flags: CGEventFlags = .maskCommand, type: CGEventType = .keyDown) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)!
            event.type = type
            event.flags = flags
            return manager.handle(type: type, event: event) == nil
        }

        func release(keeping flags: CGEventFlags = []) {
            send(kVK_Command, flags: flags, type: .flagsChanged)
        }
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testRecordingPassesConfiguredShortcutThroughAndResumesAfterward() async {
        let fixture = Fixture()
        let token = UUID()
        fixture.recording.begin(owner: token)
        XCTAssertFalse(fixture.send())
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        fixture.recording.end(owner: token)
        XCTAssertTrue(fixture.send())
        await drain()
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testStartingRecorderCancelsAlreadyQueuedInputWithoutCommitting() async {
        let fixture = Fixture()
        fixture.send()
        fixture.release()
        fixture.recording.begin(owner: UUID())
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
    }

    func testReservedShortcutIsDeliveredToRecorderInsteadOfSystemOrSwitcher() async {
        let fixture = Fixture()
        var keys: [Int] = []
        var modifiers: [CGEventFlags] = []
        let owner = UUID()
        fixture.recording.begin(owner: owner) { key, flags in keys.append(key); modifiers.append(flags) }
        XCTAssertTrue(fixture.send(kVK_Tab, flags: .maskCommand))
        XCTAssertTrue(fixture.send(kVK_Escape, flags: []))
        await drain()
        XCTAssertEqual(keys, [kVK_Tab, kVK_Escape])
        XCTAssertEqual(modifiers, [.maskCommand, []])
        XCTAssertFalse(fixture.model.isArmed)
        fixture.recording.end(owner: owner)
        fixture.send()
        await drain()
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testColdDiscoveryQueuesRapidReleaseAndLaterSessionInOrder() async {
        let gate = DiscoveryGate()
        let fixture = Fixture(prepareSnapshot: { _ in await gate.wait() })
        fixture.send()
        fixture.release()
        fixture.send(flags: [.maskCommand, .maskShift])
        fixture.release()
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
        await gate.release()
        for _ in 0..<100 where fixture.focus.windowIDs.count < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.focus.windowIDs, [2, 3])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testUninstallDuringColdDiscoveryCannotReopenOrCommit() async {
        let gate = DiscoveryGate()
        let fixture = Fixture(prepareSnapshot: { _ in await gate.wait() })
        fixture.send()
        fixture.release()
        await drain()
        fixture.manager.uninstall()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
    }

    func testSearchAndEscapeStayOrderedDuringColdDiscovery() async {
        let gate = DiscoveryGate()
        let fixture = Fixture(prepareSnapshot: { _ in await gate.wait() })
        fixture.send()
        fixture.send(kVK_ANSI_H)
        fixture.send(kVK_Escape)
        await drain()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
        XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
    }

    func testTypingChatWhileHoldingCommandDoesNotHideApp() async {
        let fixture = Fixture()
        fixture.send()
        await drain()
        for key in [kVK_ANSI_C, kVK_ANSI_H, kVK_ANSI_A, kVK_ANSI_T] {
            XCTAssertTrue(fixture.send(key))
            await drain()
        }
        XCTAssertEqual(fixture.model.filterText.lowercased(), "chat")
        XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
        XCTAssertTrue(fixture.focus.closedWindowIDs.isEmpty)
    }

    func testHeldShortcutAcceptsSpaceInCrossFieldSearchAndCommitsMatchingWindow() async {
        for modifier in [CGEventFlags.maskCommand, .maskAlternate] {
            let fixture = Fixture()
            XCTAssertTrue(fixture.send(flags: modifier))
            await drain()
            for key in [kVK_ANSI_E, kVK_ANSI_X, kVK_ANSI_A, kVK_ANSI_M, kVK_ANSI_P,
                        kVK_ANSI_L, kVK_ANSI_E, kVK_Space, kVK_ANSI_2] {
                XCTAssertTrue(fixture.send(key, flags: modifier))
                await drain()
            }
            XCTAssertEqual(fixture.model.filterText.lowercased(), "example 2")
            XCTAssertEqual(fixture.model.filteredFlatWindows.map(\.id), [2])
            fixture.release()
            await drain()
            XCTAssertEqual(fixture.focus.windowIDs, [2])
            XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
            XCTAssertTrue(fixture.focus.closedWindowIDs.isEmpty)
        }
    }

    func testHAndWCanStartASearchWithoutWindowActions() async {
        for key in [kVK_ANSI_H, kVK_ANSI_W] {
            let fixture = Fixture()
            fixture.send()
            await drain()
            XCTAssertTrue(fixture.send(key))
            await drain()
            XCTAssertEqual(fixture.model.filterText.lowercased(), key == kVK_ANSI_H ? "h" : "w")
            XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
            XCTAssertTrue(fixture.focus.closedWindowIDs.isEmpty)
        }
    }

    func testPendingSearchKeepsHAndWAsText() async {
        let fixture = Fixture()
        fixture.send()
        for key in [kVK_ANSI_C, kVK_ANSI_H, kVK_ANSI_A, kVK_ANSI_T, kVK_ANSI_W] {
            XCTAssertTrue(fixture.send(key))
        }
        await drain()
        XCTAssertEqual(fixture.model.filterText.lowercased(), "chatw")
        XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
        XCTAssertTrue(fixture.focus.closedWindowIDs.isEmpty)
    }

    func testControlCommandHAndWRemainDeliberateActions() async {
        for key in [kVK_ANSI_H, kVK_ANSI_W] {
            let fixture = Fixture()
            fixture.send()
            await drain()
            XCTAssertTrue(fixture.send(key, flags: [.maskCommand, .maskControl]))
            await drain()
            XCTAssertTrue(fixture.model.filterText.isEmpty)
            XCTAssertEqual(fixture.focus.hiddenAppPIDs, key == kVK_ANSI_H ? [101] : [])
            XCTAssertEqual(fixture.focus.closedWindowIDs, key == kVK_ANSI_W ? [2] : [])
        }
    }

    func testModifiersAlreadyRequiredByBindingCannotTriggerWindowActions() async {
        let variants: [CGEventFlags] = [[.maskCommand, .maskControl], [.maskCommand, .maskControl, .maskShift]]
        for flags in variants {
            let fixture = Fixture(primary: [.maskCommand, .maskControl])
            fixture.send(flags: [.maskCommand, .maskControl])
            await drain()
            fixture.send(kVK_ANSI_H, flags: flags)
            fixture.send(kVK_ANSI_W, flags: flags)
            await drain()
            XCTAssertEqual(fixture.model.filterText.lowercased(), "hw")
            XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
            XCTAssertTrue(fixture.focus.closedWindowIDs.isEmpty)
        }
    }

    func testCapitalLettersDoNotTriggerWindowActions() async {
        let fixture = Fixture()
        fixture.send()
        await drain()
        fixture.send(kVK_ANSI_H, flags: [.maskCommand, .maskShift])
        fixture.send(kVK_ANSI_W, flags: [.maskCommand, .maskShift])
        await drain()
        XCTAssertEqual(fixture.model.filterText, "HW")
        XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
        XCTAssertTrue(fixture.focus.closedWindowIDs.isEmpty)
    }

    func testCurrentAppSearchAlsoKeepsHAndWAsText() async {
        let fixture = Fixture()
        fixture.send(flags: .maskAlternate)
        await drain()
        fixture.send(kVK_ANSI_H, flags: .maskAlternate)
        fixture.send(kVK_ANSI_W, flags: .maskAlternate)
        await drain()
        XCTAssertEqual(fixture.model.filterText.lowercased(), "hw")
        XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
        XCTAssertTrue(fixture.focus.closedWindowIDs.isEmpty)
    }

    func testCurrentAppActionsUseSameExplicitControlCommandChord() async {
        let fixture = Fixture()
        fixture.send(flags: .maskAlternate)
        await drain()
        fixture.send(kVK_ANSI_H, flags: [.maskAlternate, .maskCommand, .maskControl])
        await drain()
        XCTAssertEqual(fixture.focus.hiddenAppPIDs, [101])
        XCTAssertTrue(fixture.model.filterText.isEmpty)
    }

    func testCommandHOutsideSwitcherIsNotIntercepted() {
        let fixture = Fixture()
        XCTAssertFalse(fixture.send(kVK_ANSI_H))
        XCTAssertTrue(fixture.focus.hiddenAppPIDs.isEmpty)
    }

    func testForwardOpenAndReleaseCommitsNextWindow() async {
        let fixture = Fixture()
        XCTAssertTrue(fixture.send())
        await drain()
        XCTAssertTrue(fixture.model.isArmed)
        XCTAssertEqual(fixture.model.selectedFlatIndex, 1)
        fixture.release()
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [2])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testReverseShortcutOpensAtPreviousWindow() async {
        let fixture = Fixture()
        XCTAssertTrue(fixture.send(flags: [.maskCommand, .maskShift]))
        await drain()
        XCTAssertTrue(fixture.model.isArmed)
        XCTAssertEqual(fixture.model.selectedFlatIndex, 2)
    }

    func testReverseShortcutAdvancesBackwardWhileArmed() async {
        let fixture = Fixture()
        fixture.send()
        await drain()
        fixture.send(flags: [.maskCommand, .maskShift])
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 0)
    }

    func testRapidPressReleaseDoesNotLeavePickerArmed() async {
        let fixture = Fixture()
        fixture.send()
        fixture.release()
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertEqual(fixture.focus.windowIDs, [2])
    }

    func testPendingRepeatedTabsAreProcessedBeforeRelease() async {
        let fixture = Fixture()
        fixture.send()
        fixture.send()
        fixture.release()
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [3])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testReleaseDuringOpeningEnumerationIsNotLost() async {
        var release: (() -> Void)?
        let fixture = Fixture(beforeEnumeration: { release?() })
        release = { [weak fixture] in fixture?.release() }
        fixture.send()
        await drain()
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertEqual(fixture.focus.windowIDs, [2])
    }

    func testBackToBackPendingSessionsCommitInOrder() async {
        let fixture = Fixture()
        fixture.send()
        fixture.release()
        fixture.send(flags: [.maskAlternate, .maskShift])
        fixture.release()
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [2, 3])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testPrimaryReleaseDoesNotWaitForSecondaryModifier() async {
        let fixture = Fixture()
        fixture.send()
        await drain()
        fixture.release(keeping: .maskAlternate)
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertEqual(fixture.focus.windowIDs, [2])
    }

    func testSecondaryReleaseDoesNotWaitForPrimaryModifier() async {
        let fixture = Fixture()
        fixture.send(flags: .maskAlternate)
        await drain()
        XCTAssertEqual(fixture.model.mode, .currentAppWindows)
        fixture.release(keeping: .maskCommand)
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertEqual(fixture.focus.windowIDs, [2])
    }

    func testReleasingAnyRequiredChordModifierCommits() async {
        let fixture = Fixture(primary: [.maskCommand, .maskControl])
        fixture.send(flags: [.maskCommand, .maskControl])
        fixture.release(keeping: .maskControl)
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertEqual(fixture.focus.windowIDs, [2])
    }

    func testReleasingOptionalReverseShiftDoesNotCommit() async {
        let fixture = Fixture()
        fixture.send(flags: [.maskCommand, .maskShift])
        fixture.release(keeping: .maskCommand)
        await drain()
        XCTAssertTrue(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
        fixture.release()
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [3])
    }

    func testBindingThatRequiresShiftUsesItForForwardAndRelease() async {
        let fixture = Fixture(primary: [.maskCommand, .maskShift], shiftCycles: true)
        XCTAssertFalse(fixture.send())
        XCTAssertTrue(fixture.send(flags: [.maskCommand, .maskShift]))
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 1)
        fixture.release(keeping: .maskCommand)
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [2])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testExactSecondaryBindingWinsOverPrimaryReverseVariant() async {
        let fixture = Fixture(secondary: [.maskCommand, .maskShift])
        fixture.send(flags: [.maskCommand, .maskShift])
        await drain()
        XCTAssertEqual(fixture.model.mode, .currentAppWindows)
        XCTAssertEqual(fixture.model.selectedFlatIndex, 1)
    }

    func testCustomKeySupportsReverseAndGenericTabNavigation() async {
        let fixture = Fixture(primaryKey: kVK_ANSI_A)
        fixture.send(kVK_ANSI_A, flags: [.maskCommand, .maskShift])
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 2)
        fixture.send(flags: [.maskCommand, .maskShift])
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 1)
    }

    func testShiftPressAndFollowingShiftTabDoNotDoubleAdvance() async {
        let fixture = Fixture(shiftCycles: true)
        fixture.send()
        await drain()
        fixture.send(kVK_Shift, flags: [.maskCommand, .maskShift], type: .flagsChanged)
        fixture.send(flags: [.maskCommand, .maskShift])
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 0)
        fixture.send(flags: [.maskCommand, .maskShift])
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 2)
    }

    func testStandaloneShiftCyclingUsesOnlyActiveBinding() async {
        let fixture = Fixture(secondary: [.maskAlternate, .maskShift], shiftCycles: true)
        fixture.send()
        fixture.send(kVK_Shift, flags: [.maskCommand, .maskShift], type: .flagsChanged)
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 0)
        fixture.release(keeping: .maskCommand)
        fixture.send(kVK_Shift, flags: [.maskCommand, .maskShift], type: .flagsChanged)
        await drain()
        XCTAssertEqual(fixture.model.selectedFlatIndex, 2)
    }

    func testEscapeBeforeOpeningCancelsWithoutCommitting() async {
        let fixture = Fixture()
        fixture.send()
        XCTAssertTrue(fixture.send(kVK_Escape))
        fixture.release()
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
    }

    func testReturnThenModifierReleaseCommitsOnlyOnce() async {
        let fixture = Fixture()
        fixture.send()
        fixture.send(kVK_Return)
        fixture.release()
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [2])
    }

    func testExternalCancellationDoesNotLetLateReleaseCommitAnotherSession() async {
        let fixture = Fixture()
        fixture.send()
        await drain()
        fixture.model.cancel()
        fixture.release()
        fixture.send(flags: .maskAlternate)
        await drain()
        XCTAssertTrue(fixture.model.isArmed)
        XCTAssertEqual(fixture.model.mode, .currentAppWindows)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
    }

    func testUninstallInvalidatesPendingOpeningAndRelease() async {
        let fixture = Fixture()
        fixture.send()
        fixture.release()
        fixture.manager.uninstall()
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
    }

    func testUninstallDuringEnumerationCannotLeaveAnOrphanedPicker() async {
        var uninstall: (() -> Void)?
        let fixture = Fixture(beforeEnumeration: { uninstall?() })
        uninstall = { [weak fixture] in fixture?.manager.uninstall() }
        fixture.send()
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
        XCTAssertTrue(fixture.focus.windowIDs.isEmpty)
    }

    func testMissingWindowsDoNotKeepInterceptingNavigation() async {
        let fixture = Fixture(hasWindows: false)
        fixture.send()
        await drain()
        XCTAssertFalse(fixture.send(kVK_DownArrow))
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testActiveBindingIsStableAcrossPreferenceChanges() async {
        let fixture = Fixture()
        fixture.send()
        await drain()
        fixture.defaults.set(Int(CGEventFlags.maskControl.rawValue), forKey: Preferences.Key.hotkeyModifierFlags)
        fixture.release(keeping: .maskControl)
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [2])
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testUnrelatedModifiersDoNotOpenSwitcher() async {
        let fixture = Fixture()
        XCTAssertFalse(fixture.send(flags: [.maskCommand, .maskControl]))
        await drain()
        XCTAssertFalse(fixture.model.isArmed)
    }

    func testDeviceModifierBitsDoNotAffectMatchingOrRelease() async {
        let fixture = Fixture()
        XCTAssertTrue(fixture.send(flags: [.maskCommand, .maskNumericPad, .maskAlphaShift]))
        fixture.release(keeping: .maskAlphaShift)
        await drain()
        XCTAssertEqual(fixture.focus.windowIDs, [2])
        XCTAssertFalse(fixture.model.isArmed)
    }
}
