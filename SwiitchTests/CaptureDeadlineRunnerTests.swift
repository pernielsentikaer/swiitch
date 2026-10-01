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

    func testTimeoutReleasesCallerButKeepsNonCooperativeWorkerBounded() async {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let completion = DeadlineCompletion()
        let request = Task {
            let value = await runner.run(timeout: 0.03) { await gate.wait(); return 7 }
            await completion.finish(value)
        }
        await waitUntil("the deadline to release the caller") { await completion.finished }
        let active = await runner.activeOperationCount
        XCTAssertEqual(active, 1, "The non-cooperative worker keeps its slot past the deadline")
        let refused = await runner.run(timeout: 0.03) { 8 }
        XCTAssertNil(refused)
        await gate.release()
        await request.value
        await waitUntil("the released worker to free its slot") { await runner.activeOperationCount == 0 }
        let recovered = await runner.run(timeout: 1) { 9 }
        XCTAssertEqual(recovered, 9)
        let old = await completion.value
        XCTAssertNil(old, "A late result cannot replace the expired result")
    }

    func testCancellationReleasesCallerWithoutWaitingForNativeWork() async {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let completion = DeadlineCompletion()
        let request = Task {
            let value = await runner.run(timeout: 5) { await gate.wait(); return 7 }
            await completion.finish(value)
        }
        await waitUntil("the native work to start") { await runner.activeOperationCount == 1 }
        request.cancel()
        await waitUntil("cancellation to release the caller") { await completion.finished }
        await gate.release()
        await request.value
        let value = await completion.value
        XCTAssertNil(value)
    }

    func testSaturatedRunnerQueuesCallerUntilSlotFreesInsteadOfFailing() async {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let blocker = Task {
            await runner.run(timeout: 5) { await gate.wait(); return 1 }
        }
        await waitUntil("the blocker to occupy the only slot") { await runner.activeOperationCount == 1 }
        let queued = Task {
            await runner.run(timeout: 1) { 2 }
        }
        await waitUntil("a saturated runner to queue, not refuse, a caller within its timeout") {
            await runner.waitingOperationCount == 1
        }
        await gate.release()
        let first = await blocker.value
        let second = await queued.value
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2, "The queued capture runs once the stuck slot is released")
        let active = await runner.activeOperationCount
        XCTAssertEqual(active, 0)
    }

    func testCancellingQueuedCallerReleasesItImmediately() async {
        let runner = CaptureDeadlineRunner(limit: 1)
        let gate = NativeCaptureGate()
        let blocker = Task {
            await runner.run(timeout: 5) { await gate.wait(); return 1 }
        }
        await waitUntil("the blocker to occupy the only slot") { await runner.activeOperationCount == 1 }
        let completion = DeadlineCompletion()
        let queued = Task {
            let value = await runner.run(timeout: 5) { 2 }
            await completion.finish(value)
        }
        await waitUntil("the caller to queue behind the blocker") { await runner.waitingOperationCount == 1 }
        queued.cancel()
        await waitUntil("a cancelled queued caller to return without waiting for the native slot") {
            await completion.finished
        }
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
