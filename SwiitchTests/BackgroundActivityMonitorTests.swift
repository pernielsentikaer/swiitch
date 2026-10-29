import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class BackgroundActivityMonitorTests: XCTestCase {
    func testNativeDistributedCenterAcceptsImmediateRegistrationAndCleanup() {
        // Exercise the selector-based production registration too. Only listen: never
        // post system lock notifications or change the real notification center's state.
        var changes: [Bool] = []
        let monitor = BackgroundActivityMonitor(workspace: NotificationCenter(),
            initialState: { .init() }, onPauseChange: { changes.append($0) })
        monitor.start()
        monitor.stop()
        monitor.start()
        monitor.stop()
        XCTAssertEqual(changes, [false, false])
    }

    func testOverlappingPauseReasonsMustAllClearBeforeResuming() {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var changes: [Bool] = []
        let monitor = BackgroundActivityMonitor(workspace: workspace, distributed: distributed,
            initialState: { .init() }, onPauseChange: { changes.append($0) })
        monitor.start()
        defer { monitor.stop() }
        distributed.post(name: BackgroundActivityMonitor.screenLocked, object: nil)
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertEqual(changes, [false, true])
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        distributed.post(name: BackgroundActivityMonitor.screenUnlocked, object: nil)
        XCTAssertTrue(monitor.state.isPaused, "A different console session still owns the Mac")
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(changes, [false, true, false])
    }

    func testInitialStateDuplicateEventsAndStopRestartAreSafe() {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var changes: [Bool] = []
        let monitor = BackgroundActivityMonitor(workspace: workspace, distributed: distributed,
            initialState: { .init(screenLocked: true) }, onPauseChange: { changes.append($0) })
        monitor.start()
        monitor.start()
        distributed.post(name: BackgroundActivityMonitor.screenLocked, object: nil)
        XCTAssertEqual(changes, [true], "Starting locked must not briefly enable background work")
        monitor.stop()
        distributed.post(name: BackgroundActivityMonitor.screenUnlocked, object: nil)
        XCTAssertEqual(changes, [true])
        monitor.start()
        distributed.post(name: BackgroundActivityMonitor.screenUnlocked, object: nil)
        distributed.post(name: BackgroundActivityMonitor.screenUnlocked, object: nil)
        XCTAssertEqual(changes, [true, true, false])
        monitor.stop()
    }

    func testStateUsesAnyPauseReasonAndNormalStateResumes() {
        XCTAssertFalse(BackgroundActivityMonitor.State().isPaused)
        XCTAssertTrue(BackgroundActivityMonitor.State(systemSleeping: true).isPaused)
        XCTAssertTrue(BackgroundActivityMonitor.State(displaysSleeping: true).isPaused)
        XCTAssertTrue(BackgroundActivityMonitor.State(sessionInactive: true).isPaused)
        XCTAssertTrue(BackgroundActivityMonitor.State(screenLocked: true).isPaused)
    }
}
