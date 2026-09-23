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

    func testSaturatedRunnerQueuesCallerUntilSlotFreesInsteadOfFailing() async throws {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let blocker = Task {
            await runner.run(timeout: 5) { await gate.wait(); return 1 }
        }
        try await Task.sleep(for: .milliseconds(30))
        let queued = Task {
            await runner.run(timeout: 1) { 2 }
        }
        try await Task.sleep(for: .milliseconds(30))
        let waiting = await runner.waitingOperationCount
        XCTAssertEqual(waiting, 1, "A saturated runner must queue, not refuse, a caller within its timeout")
        await gate.release()
        let first = await blocker.value
        let second = await queued.value
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2, "The queued capture runs once the stuck slot is released")
        let active = await runner.activeOperationCount
        XCTAssertEqual(active, 0)
    }

    func testCancellingQueuedCallerReleasesItImmediately() async throws {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let blocker = Task {
            await runner.run(timeout: 5) { await gate.wait(); return 1 }
        }
        try await Task.sleep(for: .milliseconds(30))
        let completion = DeadlineCompletion()
        let queued = Task {
            let value = await runner.run(timeout: 5) { 2 }
            await completion.finish(value)
        }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        try await Task.sleep(for: .milliseconds(50))
        let finished = await completion.finished
        XCTAssertTrue(finished, "A cancelled queued caller must not wait for the native slot")
        let waiting = await runner.waitingOperationCount
        XCTAssertEqual(waiting, 0)
        await gate.release()
        _ = await blocker.value
        await queued.value
        let value = await completion.value
        XCTAssertNil(value)
        let recovered = await runner.run(timeout: 1) { 3 }
        XCTAssertEqual(recovered, 3, "A cancelled waiter must not leak a reserved slot")
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
