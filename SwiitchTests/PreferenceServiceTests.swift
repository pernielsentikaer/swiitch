@testable import Swiitch
import XCTest

@MainActor
final class PreferenceServiceTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    func testLoginStatusRefreshIsReadOnlyAndReflectsExternalChanges() {
        var status = LoginItemController.Status.enabled
        var registrations = 0
        let controller = LoginItemController(dependencies: .init(
            status: { status }, register: { registrations += 1 }, unregister: { XCTFail("Unexpected unregister") }
        ))
        XCTAssertTrue(controller.isRequested)
        status = .disabled
        controller.refresh()
        XCTAssertFalse(controller.isRequested)
        XCTAssertEqual(registrations, 0)
    }

    func testLoginApprovalIsNotMisreportedAsEnabledOrRegisteredRepeatedly() {
        var status = LoginItemController.Status.disabled
        var registrations = 0
        let controller = LoginItemController(dependencies: .init(
            status: { status }, register: { registrations += 1; status = .requiresApproval },
            unregister: { status = .disabled }
        ))
        controller.setEnabled(true)
        controller.setEnabled(true)
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isRequested)
        XCTAssertEqual(registrations, 1)
        controller.setEnabled(false)
        XCTAssertEqual(controller.status, .disabled)
    }

    func testLoginRegistrationAndRemovalFailuresKeepActualState() {
        for status in [LoginItemController.Status.disabled, .enabled] {
            let controller = LoginItemController(dependencies: .init(
                status: { status }, register: { throw Failure.unavailable }, unregister: { throw Failure.unavailable }
            ))
            controller.setEnabled(status == .disabled)
            XCTAssertEqual(controller.status, status)
            XCTAssertNotNil(controller.errorMessage)
            controller.refresh()
            XCTAssertNotNil(controller.errorMessage)
        }
    }

    func testUpdateStartupPreservesDisabledChecksAndNeverForcesACheck() {
        var enabled = false
        var starts = 0, checks = 0, writes = 0
        let controller = UpdateController(backend: .init(
            readAutomatic: { enabled }, writeAutomatic: { enabled = $0; writes += 1 },
            start: { starts += 1 }, checkManually: { checks += 1 }
        ))
        XCTAssertEqual(starts, 0, "Opening settings must not start the updater")
        controller.arm()
        controller.arm()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(checks, 0)
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(controller.automaticChecksEnabled)
        controller.checkForUpdates()
        XCTAssertEqual(checks, 1, "Manual checks remain available when automatic checks are off")
        XCTAssertFalse(enabled)
        controller.setAutomaticChecksEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(controller.automaticChecksEnabled)
        XCTAssertEqual(checks, 1)
        enabled = false
        controller.refreshSettings()
        XCTAssertFalse(controller.automaticChecksEnabled)
    }

    func testScheduledUpdateShownBehindOtherAppsBecomesAMenuBarReminder() {
        let controller = UpdateController(backend: .init(
            readAutomatic: { false }, writeAutomatic: { _ in }, start: {}, checkManually: {}
        ))
        XCTAssertNil(controller.pendingUpdateVersion)
        controller.noteScheduledUpdate(version: "0.2.0", shownBySparkle: false)
        XCTAssertEqual(controller.pendingUpdateVersion, "0.2.0", "An alert Sparkle does not focus must be surfaced by Swiitch")
        controller.clearPendingUpdate()
        XCTAssertNil(controller.pendingUpdateVersion, "User attention or a finished session clears the reminder")
        controller.noteScheduledUpdate(version: "0.2.1", shownBySparkle: true)
        XCTAssertNil(controller.pendingUpdateVersion, "No duplicate reminder when Sparkle shows the alert in focus")
    }

    func testUpdaterStartFailureIsVisibleAndRetryable() {
        var fail = true
        var checks = 0
        let controller = UpdateController(backend: .init(
            readAutomatic: { false }, writeAutomatic: { _ in },
            start: { if fail { throw Failure.unavailable } }, checkManually: { checks += 1 }
        ))
        controller.checkForUpdates()
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(checks, 0)
        fail = false
        controller.checkForUpdates()
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(checks, 1)
    }
}
