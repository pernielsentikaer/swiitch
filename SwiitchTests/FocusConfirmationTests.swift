import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class FocusConfirmationTests: XCTestCase {
    private var confirmation = FocusConfirmation()
    private var pid: pid_t? = 101
    private var windowID: CGWindowID? = 1
    private var records: [CGWindowID?] = []
    private var callbacks: [@MainActor @Sendable () -> Void] = []

    private func start(targetPID: pid_t = 102, targetWindowID: CGWindowID? = 2) {
        confirmation.start(
            pid: targetPID, windowID: targetWindowID, sourcePID: 101,
            frontmostPID: { self.pid }, focusedWindowID: { _ in self.windowID },
            record: { self.records.append($0) }, enqueue: { self.callbacks.append($0) }
        )
    }

    func testDelayedHandoffRequiresTheExactWindowNotJustItsApp() {
        start()
        pid = 102
        windowID = 3
        callbacks.removeFirst()()
        XCTAssertTrue(records.isEmpty)
        windowID = 2
        let completion = callbacks.removeFirst()
        completion()
        completion()
        XCTAssertEqual(records, [2])
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testRejectedSameAppWindowSwitchNeverRecordsRequestedSibling() {
        start(targetPID: 101, targetWindowID: 2)
        var attempts = 0
        while !callbacks.isEmpty && attempts < 5 {
            callbacks.removeFirst()()
            attempts += 1
            XCTAssertLessThanOrEqual(attempts, 3)
        }
        XCTAssertEqual(attempts, 3, "One immediate check plus three bounded delayed checks")
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertTrue(records.isEmpty)
    }

    func testAppSelectionRecordsActualWindowNotCachedFirstWindow() {
        pid = 102
        windowID = 9
        start(targetWindowID: nil)
        XCTAssertEqual(records, [9])
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testWindowlessAppConfirmsOnlyAppFocus() {
        pid = 102
        windowID = 0
        start(targetWindowID: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0])
    }

    func testUnknownWindowIDDoesNotConfirmWindowSelection() {
        pid = 102
        windowID = nil
        start()
        XCTAssertTrue(records.isEmpty)
        windowID = 2
        callbacks.removeFirst()()
        XCTAssertEqual(records, [2])
    }

    func testThirdAppAbandonsHandoffEvenIfTargetLaterBecomesActive() {
        start()
        pid = 103
        let completion = callbacks.removeFirst()
        completion()
        pid = 102
        windowID = 2
        completion()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testCancellationAndNewRequestsInvalidateOldChecks() {
        start()
        confirmation.cancel()
        pid = 102
        windowID = 2
        callbacks.removeFirst()()
        XCTAssertTrue(records.isEmpty)
        pid = 101
        start()
        let oldCheck = callbacks.removeFirst()
        start(targetWindowID: 3)
        pid = 102
        oldCheck()
        XCTAssertTrue(records.isEmpty)
        windowID = 3
        callbacks.removeFirst()()
        XCTAssertEqual(records, [3])
    }

    func testAppChangingDuringAXReadDoesNotRecordStaleFocus() {
        pid = 102
        confirmation.start(
            pid: 102, windowID: 2, sourcePID: 101,
            frontmostPID: { self.pid },
            focusedWindowID: { _ in self.pid = 103; return 2 },
            record: { self.records.append($0) }, enqueue: { self.callbacks.append($0) }
        )
        callbacks.removeFirst()()
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testReleasedCoordinatorDoesNotRecordDelayedFocus() {
        var pending: FocusConfirmation? = .init()
        pending?.start(
            pid: 102, windowID: 2, sourcePID: 101,
            frontmostPID: { self.pid }, focusedWindowID: { _ in self.windowID },
            record: { self.records.append($0) }, enqueue: { self.callbacks.append($0) }
        )
        pending = nil
        pid = 102
        windowID = 2
        callbacks.removeFirst()()
        XCTAssertTrue(records.isEmpty)
    }
}
