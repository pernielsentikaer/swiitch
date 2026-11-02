import AppKit

extension WindowFocuser {
    /// One cooperative budget for the whole focus intent, not a fresh timeout per
    /// candidate or reassertion. OS calls may overrun; never start another after expiry.
    final class FocusBudget {
        private let now: () -> TimeInterval
        private let deadline: TimeInterval

        init(seconds: TimeInterval = 0.25,
             now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
            self.now = now
            deadline = now() + seconds
        }

        var hasTime: Bool { !Task.isCancelled && deadline - now() > 0.001 }

        func timeout(maximum: Float) -> Float? {
            guard hasTime else { return nil }
            let remaining = Float(deadline - now())
            guard remaining > 0.001 else { return nil }
            return min(maximum, remaining)
        }
    }

    /// Read one app's AX window list once per focus request. Memoize even unavailable
    /// metadata so retries cannot multiply expensive bridge reads. Never reused across
    /// requests or processes; native identity is still revalidated before raising.
    final class FocusLookup<Element> {
        let budget: FocusBudget
        private let load: (Float) -> [Element]?
        private let readID: (Element) -> CGWindowID?
        private let readTitle: (Element) -> String
        private let readBounds: (Element) -> CGRect?
        private var didLoad = false
        private var elements: [Element] = []
        private var ids: [Int: CGWindowID?] = [:]
        private var titles: [Int: String] = [:]
        private var bounds: [Int: CGRect?] = [:]

        init(budget: FocusBudget, load: @escaping (Float) -> [Element]?,
             windowID: @escaping (Element) -> CGWindowID?,
             title: @escaping (Element) -> String, bounds: @escaping (Element) -> CGRect?) {
            self.budget = budget
            self.load = load
            readID = windowID
            readTitle = title
            readBounds = bounds
        }

        func resolve(_ window: WindowInfo, purpose: MatchingPurpose = .focus) -> Element? {
            guard budget.hasTime else { return nil }
            if !didLoad {
                didLoad = true
                guard let timeout = budget.timeout(maximum: 0.03) else { return nil }
                elements = load(timeout) ?? []
            }
            let index = matchingFocusCandidateIndex(
                for: window, count: elements.count, purpose: purpose,
                windowID: { index in
                    if let cached = self.ids[index] { return cached }
                    let value = self.readID(self.elements[index])
                    self.ids.updateValue(value, forKey: index)
                    return value
                },
                title: { index in
                    if let cached = self.titles[index] { return cached }
                    let value = self.readTitle(self.elements[index])
                    self.titles[index] = value
                    return value
                },
                bounds: { index in
                    if let cached = self.bounds[index] { return cached }
                    let value = self.readBounds(self.elements[index])
                    self.bounds.updateValue(value, forKey: index)
                    return value
                },
                hasTime: { self.budget.hasTime }
            )
            return index.map { elements[$0] }
        }
    }
}
