import AppKit

/// A focus request is not proof of a completed handoff. Observe briefly, without
/// activating anything, before repairing MRU for apps that omit AX notifications.
@MainActor
final class FocusConfirmation {
    private var generation: UInt64 = 0

    func cancel() {
        generation &+= 1
    }

    func start(
        pid: pid_t,
        windowID: CGWindowID?,
        sourcePID: pid_t?,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        focusedWindowID: @escaping @MainActor (pid_t) -> CGWindowID?,
        record: @escaping @MainActor (CGWindowID?) -> Void,
        enqueue: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        cancel()
        check(pid: pid, windowID: windowID, sourcePID: sourcePID, request: generation,
              remaining: 3, frontmostPID: frontmostPID, focusedWindowID: focusedWindowID,
              record: record, enqueue: enqueue)
    }

    private func check(
        pid: pid_t,
        windowID: CGWindowID?,
        sourcePID: pid_t?,
        request: UInt64,
        remaining: Int,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        focusedWindowID: @escaping @MainActor (pid_t) -> CGWindowID?,
        record: @escaping @MainActor (CGWindowID?) -> Void,
        enqueue: @escaping (@escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        guard generation == request else { return }
        let currentPID = frontmostPID()
        // Abandon the handoff if the user has moved to a third app in the meantime.
        guard currentPID == nil || currentPID == pid || currentPID == sourcePID else {
            cancel()
            return
        }
        if currentPID == pid {
            let actualID = focusedWindowID(pid).flatMap { $0 == kCGNullWindowID ? nil : $0 }
            if (windowID == nil || actualID == windowID), frontmostPID() == pid,
               generation == request {
                cancel()
                record(actualID)
                return
            }
        }
        guard remaining > 0 else { cancel(); return }
        enqueue { [weak self] in
            self?.check(pid: pid, windowID: windowID, sourcePID: sourcePID, request: request,
                        remaining: remaining - 1, frontmostPID: frontmostPID,
                        focusedWindowID: focusedWindowID, record: record, enqueue: enqueue)
        }
    }
}
