import Foundation
@testable import Swiitch
import XCTest

final class CaptureDeadlineRunnerTests: XCTestCase {
    func testCompletedOperationReturnsItsValueAndReleasesSlot() async {
        let runner = CaptureDeadlineRunner(limit: 1)
        let value = await runner.run(timeout: 1) { 42 }
        XCTAssertEqual(value, 42)
        let active = await runner.activeOperationCount
        XCTAssertEqual(active, 0)
        let next = await runner.run(timeout: 1) { 43 }
        XCTAssertEqual(next, 43)
    }

    func testTimeoutReleasesCallerButKeepsNonCooperativeWorkerBounded() async throws {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let completion = DeadlineCompletion()
        let request = Task {
            let value = await runner.run(timeout: 0.03) { await gate.wait(); return 7 }
            await completion.finish(value)
        }
        try await Task.sleep(for: .milliseconds(100))
        let finished = await completion.finished
        XCTAssertTrue(finished)
        let active = await runner.activeOperationCount
        XCTAssertEqual(active, 1)
        let refused = await runner.run(timeout: 0.03) { 8 }
        XCTAssertNil(refused)
        await gate.release()
        await request.value
        for _ in 0..<100 {
            if await runner.activeOperationCount == 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let recovered = await runner.run(timeout: 1) { 9 }
        XCTAssertEqual(recovered, 9)
        let old = await completion.value
        XCTAssertNil(old, "A late result cannot replace the expired result")
    }

    func testCancellationReleasesCallerWithoutWaitingForNativeWork() async throws {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let completion = DeadlineCompletion()
        let request = Task {
            let value = await runner.run(timeout: 5) { await gate.wait(); return 7 }
            await completion.finish(value)
        }
        try await Task.sleep(for: .milliseconds(30))
        request.cancel()
        try await Task.sleep(for: .milliseconds(70))
        let finished = await completion.finished
        XCTAssertTrue(finished)
        await gate.release()
        await request.value
        let value = await completion.value
        XCTAssertNil(value)
    }
}

private actor NativeCaptureGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private actor DeadlineCompletion {
    private(set) var finished = false
    private(set) var value: Int?
    func finish(_ value: Int?) { self.value = value; finished = true }
}
