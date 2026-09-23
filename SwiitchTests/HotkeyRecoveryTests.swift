import AppKit
@testable import Swiitch
import XCTest

final class HotkeyRecoveryTests: XCTestCase {
    private final class Fixture {
        var time: TimeInterval = 0
        var trusted = true
        var enabled = false
        var success = false
        var attempts = 0
        lazy var recovery = HotkeyRecovery(dependencies: .init(
            trusted: { self.trusted }, enabled: { self.enabled },
            install: { self.attempts += 1; self.enabled = self.success; return self.success },
            now: { self.time }
        ))
    }

    func testInitialFailureRetriesWithoutPermissionTransition() {
        let f = Fixture()
        f.recovery.start()
        XCTAssertEqual(f.recovery.status, .retrying)
        f.success = true
        f.time = 1
        f.recovery.refresh()
        XCTAssertEqual(f.attempts, 2)
        XCTAssertEqual(f.recovery.status, .ready)
    }

    func testBackoffRemainsBoundedAndStopCancelsRecovery() {
        let f = Fixture()
        f.recovery.start()
        for time in [1.0, 3, 7, 15, 31, 61, 91] {
            f.time = time - 0.1
            let previous = f.attempts
            f.recovery.refresh()
            XCTAssertEqual(f.attempts, previous)
            f.time = time
            f.recovery.refresh()
            XCTAssertEqual(f.attempts, previous + 1)
        }
        f.recovery.stop()
        f.time = 500
        f.recovery.refresh(force: true)
        XCTAssertEqual(f.attempts, 8)
        XCTAssertEqual(f.recovery.status, .stopped)
    }

    func testMissingPermissionNeverAttemptsInstallationAndGrantRecovers() {
        let f = Fixture()
        f.trusted = false
        f.recovery.start()
        for _ in 0..<10 { f.recovery.refresh(force: true) }
        XCTAssertEqual(f.attempts, 0)
        XCTAssertEqual(f.recovery.status, .permissionRequired)
        f.trusted = true
        f.success = true
        f.recovery.refresh()
        XCTAssertEqual(f.recovery.status, .ready)
    }

    func testWakeCanRetryEarlyButHealthyTapDoesNotReinstall() {
        let f = Fixture()
        f.recovery.start()
        f.success = true
        f.recovery.refresh(force: true)
        for _ in 0..<10 { f.recovery.refresh(force: true); f.recovery.start() }
        XCTAssertEqual(f.attempts, 2)
        f.enabled = false
        f.recovery.refresh()
        XCTAssertEqual(f.attempts, 3)
    }

    func testRecordingSessionReplacementCannotBeEndedByPreviousOwner() {
        let recording = ShortcutRecordingSession()
        let first = UUID(), second = UUID()
        recording.begin(owner: first)
        recording.begin(owner: second)
        recording.end(owner: first)
        XCTAssertTrue(recording.isRecording)
        recording.end(owner: second)
        XCTAssertFalse(recording.isRecording)
    }

    func testShortcutConflictsIncludeReverseAndIgnoreUnrelatedFlags() {
        XCTAssertTrue(Shortcut.conflicts((48, .maskCommand), (48, .maskCommand)))
        XCTAssertTrue(Shortcut.conflicts((48, .maskCommand), (48, [.maskCommand, .maskShift])))
        XCTAssertTrue(Shortcut.conflicts((48, [.maskCommand, .maskShift]), (48, .maskCommand)))
        XCTAssertTrue(Shortcut.conflicts((48, [.maskCommand, .maskAlphaShift]), (48, .maskCommand)))
        XCTAssertFalse(Shortcut.conflicts((48, .maskCommand), (48, .maskAlternate)))
        XCTAssertFalse(Shortcut.conflicts((48, .maskCommand), (49, .maskCommand)))
    }
}
