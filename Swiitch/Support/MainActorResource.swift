import Foundation

/// Owns a native resource whose use and teardown belong to the main run loop.
/// The last Swift reference may disappear on any executor. Only a Sendable cleanup
/// closure crosses that boundary; the resource itself remains main-actor confined.
@MainActor
final class MainActorResource<Value> {
    let value: Value
    private let cleanup: MainActorCleanup

    init(_ value: Value, release: @escaping @MainActor @Sendable (Value) -> Void) {
        self.value = value
        cleanup = MainActorCleanup { release(value) }
    }
}

extension MainActorResource where Value == Timer {
    func invalidate() { value.invalidate() }
}

extension MainActorResource where Value == DispatchWorkItem {
    func cancel() { value.cancel() }
}

/// Runs synchronously when released on main, or enqueues teardown there otherwise.
/// Never captures its owner from deinit or assumes that deinit is actor-isolated.
private final class MainActorCleanup: Sendable {
    private let action: @MainActor @Sendable () -> Void

    init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    deinit {
        let action = action
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            Task { @MainActor in action() }
        }
    }
}
