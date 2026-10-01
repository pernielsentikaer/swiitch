import Foundation

/// Follows the system's memory-pressure signal. Swiitch keeps up to 96 MB of window
/// previews that are cheap to recapture, so under pressure it drops them and stops
/// refilling the cache in the background until the system reports normal again. The
/// picker's own loads keep capturing on demand throughout.
@MainActor
final class MemoryPressureMonitor {
    private let onPressure: @MainActor (Bool) -> Void
    private var source: DispatchSourceMemoryPressure?
    /// True from the last warning or critical signal until the next normal one.
    private(set) var constrained = false
    /// Warning and critical signals received since launch.
    private(set) var pressureEventCount = 0

    /// `onPressure(true)` on every warning or critical signal, even while already
    /// constrained, since the picker may have refilled the cache in between;
    /// `onPressure(false)` once when pressure returns to normal.
    init(onPressure: @escaping @MainActor (Bool) -> Void) {
        self.onPressure = onPressure
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            // The source delivers on the main queue, so this is the main actor.
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                self.handle(source.data)
            }
        }
        source.activate()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// The dispatch source's handler; tests call it directly.
    func handle(_ event: DispatchSource.MemoryPressureEvent) {
        if !event.isDisjoint(with: [.warning, .critical]) {
            pressureEventCount += 1
            constrained = true
            onPressure(true)
        } else if event.contains(.normal), constrained {
            constrained = false
            onPressure(false)
        }
    }
}
