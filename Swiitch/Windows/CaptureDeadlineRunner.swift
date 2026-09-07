import Foundation

/// Bounds native capture work even when an OS call ignores Swift task cancellation.
/// Expiry releases the caller, but its worker keeps a slot until it actually returns.
/// A task-group race would still wait for a non-cooperative losing child indefinitely.
actor CaptureDeadlineRunner {
    private let limit: Int
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    var activeOperationCount: Int { workers.count }

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    func run<Value>(
        timeout: TimeInterval,
        operation: @escaping @Sendable () async -> Value?
    ) async -> Value? {
        guard !Task.isCancelled, workers.count < limit else { return nil }
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

    private func expired(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        workers[id]?.cancel()
    }

    private func finished(_ id: UUID) {
        deadlines.removeValue(forKey: id)?.cancel()
        workers.removeValue(forKey: id)
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
