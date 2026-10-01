import Foundation
import os

/// Records how long each stage of opening the switcher takes, from the hotkey event to
/// the first preview on screen. Marks are cheap (one uptime read, no allocation on the
/// hotkey path beyond a dictionary insert) and are also emitted as signposts, so the same
/// data is visible in Instruments. Diagnostics reports percentiles over recent opens.
@MainActor
final class OpenLatency {
    static let shared = OpenLatency()

    enum Mark: String, CaseIterable, Codable {
        /// The hotkey event tap matched the shortcut and a session began.
        case hotkey
        /// The window snapshot the picker will use was ready (warm cache or fresh collection).
        case snapshotReady
        /// The model armed: lists built, selection chosen, focus captured.
        case armed
        /// The panel was laid out and ordered front (after the show delay, if any).
        case panelShown
        /// The first preview image for this open was delivered to the model.
        case firstThumbnail
    }

    /// Milliseconds after `hotkey` at which each later mark happened, for one open.
    /// Keyed by `Mark.rawValue` so it encodes as a plain JSON object.
    struct Sample: Codable, Equatable {
        var milliseconds: [String: Double]
        subscript(_ mark: Mark) -> Double? { milliseconds[mark.rawValue] }
        var shown: Bool { self[.panelShown] != nil }
    }

    struct Percentiles: Codable, Equatable {
        let count: Int
        let p50: Double
        let p95: Double
        let max: Double

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func at(_ fraction: Double) -> Double {
                sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
            }
            count = sorted.count
            p50 = (at(0.5) * 10).rounded() / 10
            p95 = (at(0.95) * 10).rounded() / 10
            max = (sorted[sorted.count - 1] * 10).rounded() / 10
        }
    }

    /// Allowlisted aggregate: counts and milliseconds only.
    struct Summary: Codable, Equatable {
        let opens: Int
        let shownOpens: Int
        let hotkeyToSnapshotMs: Percentiles?
        let hotkeyToArmedMs: Percentiles?
        let hotkeyToPanelMs: Percentiles?
        let panelToFirstThumbnailMs: Percentiles?
        let lastOpen: Sample?
    }

    static let capacity = 100

    private let now: () -> TimeInterval
    private let signposter: OSSignposter?
    private var start: TimeInterval?
    private var current: [String: Double] = [:]
    private var interval: OSSignpostIntervalState?
    private var signpostID: OSSignpostID?
    private(set) var samples: [Sample] = []

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         signposts: Bool = true) {
        self.now = now
        signposter = signposts ? OSSignposter(subsystem: "com.swiitch.Swiitch", category: "open") : nil
    }

    /// A new open is starting. A previous open that never ended is finalized first.
    func begin() {
        if start != nil { end() }
        start = now()
        current = [:]
        if let signposter {
            let id = signposter.makeSignpostID()
            signpostID = id
            interval = signposter.beginInterval("Open", id: id)
        }
    }

    /// Records the first occurrence of a mark for the current open; later calls are ignored.
    func mark(_ mark: Mark) {
        guard let start, current[mark.rawValue] == nil else { return }
        current[mark.rawValue] = (now() - start) * 1000
        if let signposter, let signpostID {
            signposter.emitEvent("Mark", id: signpostID, "\(mark.rawValue, privacy: .public)")
        }
    }

    /// The open finished (commit or cancel). Stores the sample.
    func end() {
        guard start != nil else { return }
        if let signposter, let interval { signposter.endInterval("Open", interval) }
        interval = nil
        signpostID = nil
        start = nil
        samples.append(Sample(milliseconds: current))
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        current = [:]
    }

    var summary: Summary {
        func values(_ mark: Mark) -> [Double] { samples.compactMap { $0[mark] } }
        let panelToThumbnail = samples.compactMap { sample -> Double? in
            guard let panel = sample[.panelShown], let thumbnail = sample[.firstThumbnail] else { return nil }
            return thumbnail - panel
        }
        return Summary(
            opens: samples.count,
            shownOpens: samples.filter(\.shown).count,
            hotkeyToSnapshotMs: Percentiles(values(.snapshotReady)),
            hotkeyToArmedMs: Percentiles(values(.armed)),
            hotkeyToPanelMs: Percentiles(values(.panelShown)),
            panelToFirstThumbnailMs: Percentiles(panelToThumbnail),
            lastOpen: samples.last
        )
    }
}
