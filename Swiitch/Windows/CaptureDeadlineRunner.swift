import Foundation

/// Bounds native capture work even when an OS call ignores Swift task cancellation.
/// Expiry releases the caller, but its worker keeps a slot until it actually returns.
/// A task-group race would still wait for a non-cooperative losing child indefinitely.
actor CaptureDeadlineRunner {
    private let limit: Int
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    /// Slots handed to waiters that have not yet registered their worker.
    private var reserved = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    var activeOperationCount: Int { workers.count }
    var waitingOperationCount: Int { waiters.count }

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    /// Runs `operation` in one of `limit` slots, giving up after `timeout`.
    ///
    /// A saturated runner queues the caller instead of failing it. Cancelled captures
    /// keep their slot until the OS call returns, so an interrupted background batch
    /// would otherwise make the next foreground batch fail immediately and back off
    /// windows that were never actually captured. Waiting for a slot is bounded by the
    /// same `timeout`; cancellation releases a queued caller at once.
    func run<Value>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        guard !Task.isCancelled else { return nil }
        guard await acquireSlot(timeout: timeout) else { return nil }
        let id = UUID()
        let result = CaptureDeadlineResult<Value>()
        workers[id] = Task.detached(priority: .userInitiated) { [weak self] in
            let value = await operation()
            await self?.finished(id)
            await result.resolve(value)
        }
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, timeout))) }
            catch { return }
            await result.resolve(nil)
            await self?.expired(id)
        }
        return await withTaskCancellationHandler {
            await result.value()
        } onCancel: {
            Task {
                await result.resolve(nil)
                await self.expired(id)
            }
        }
    }

    private func acquireSlot(timeout: TimeInterval) async -> Bool {
        if workers.count + reserved < limit { return true }
        let id = UUID()
        let expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.001, timeout))) }
            catch { return }
            await self?.resumeWaiter(id, granted: false)
        }
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.resumeWaiter(id, granted: false) }
        }
        expiry.cancel()
        if granted { reserved -= 1 }
        return granted
    }

    private func resumeWaiter(_ id: UUID, granted: Bool) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        if granted { reserved += 1 }
        waiter.continuation.resume(returning: granted)
    }

    private func grantFreedSlot() {
        guard workers.count + reserved < limit, let next = waiters.first else { return }
        resumeWaiter(next.id, granted: true)
    }

    private func expired(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        workers[id]?.cancel()
    }

    private func finished(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        workers.removeValue(forKey: id)
        grantFreedSlot()
    }
}

private actor CaptureDeadlineResult<Value> {
    private var resolved = false
    private var result: Value?
    private var waiter: CheckedContinuation<Value?, Never>?

    func value() async -> Value? {
        if resolved { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ value: Value?) {
        guard !resolved else { return }
        resolved = true
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }
}
