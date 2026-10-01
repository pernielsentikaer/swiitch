@testable import Swiitch
import XCTest

@MainActor
final class OpenLatencyTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }

    func testMarksAreRelativeToTheHotkeyAndOnlyTheFirstOccurrenceCounts() throws {
        let clock = Clock()
        let latency = OpenLatency(now: { clock.now }, signposts: false)
        latency.mark(.armed)
        XCTAssertTrue(latency.samples.isEmpty, "Marks before a begin are ignored")

        latency.begin()
        clock.now += 0.0005; latency.mark(.snapshotReady)
        clock.now += 0.0015; latency.mark(.armed)
        clock.now += 0.150;  latency.mark(.panelShown)
        clock.now += 0.008;  latency.mark(.firstThumbnail)
        clock.now += 0.100;  latency.mark(.firstThumbnail)
        latency.end()

        let sample = try XCTUnwrap(latency.samples.last)
        XCTAssertEqual(sample[.snapshotReady]!, 0.5, accuracy: 0.001)
        XCTAssertEqual(sample[.armed]!, 2, accuracy: 0.001)
        XCTAssertEqual(sample[.panelShown]!, 152, accuracy: 0.001)
        XCTAssertEqual(sample[.firstThumbnail]!, 160, accuracy: 0.001, "A later delivery must not move the first-thumbnail mark")
        XCTAssertTrue(sample.shown)
        XCTAssertNil(sample[.hotkey])
    }

    func testQuickReleaseOpensCountButAreNotShownAndSummaryUsesOnlyAvailableMarks() {
        let clock = Clock()
        let latency = OpenLatency(now: { clock.now }, signposts: false)
        for ms in [1.0, 2.0, 3.0, 40.0] {
            latency.begin()
            clock.now += ms / 1000; latency.mark(.armed)
            latency.end()
        }
        latency.begin()
        clock.now += 0.002; latency.mark(.armed)
        clock.now += 0.150; latency.mark(.panelShown)
        clock.now += 0.010; latency.mark(.firstThumbnail)
        latency.end()

        let summary = latency.summary
        XCTAssertEqual(summary.opens, 5)
        XCTAssertEqual(summary.shownOpens, 1)
        XCTAssertEqual(summary.hotkeyToArmedMs?.count, 5)
        XCTAssertEqual(summary.hotkeyToArmedMs?.p50, 2)
        XCTAssertEqual(summary.hotkeyToArmedMs?.max, 40)
        XCTAssertEqual(summary.hotkeyToPanelMs?.count, 1)
        XCTAssertEqual(summary.panelToFirstThumbnailMs?.p50, 10)
        XCTAssertNil(summary.hotkeyToSnapshotMs)
    }

    func testBeginFinalizesAnUnfinishedOpenAndTheBufferIsBounded() {
        let latency = OpenLatency(now: { 0 }, signposts: false)
        latency.begin()
        latency.mark(.armed)
        latency.begin()
        XCTAssertEqual(latency.samples.count, 1, "An open that never ended is stored when the next begins")
        latency.end()
        for _ in 0..<(OpenLatency.capacity + 10) { latency.begin(); latency.end() }
        XCTAssertEqual(latency.samples.count, OpenLatency.capacity)
    }

    func testPercentilesRoundToTenthsAndRejectEmptyInput() throws {
        XCTAssertNil(OpenLatency.Percentiles([]))
        let percentiles = try XCTUnwrap(OpenLatency.Percentiles([0.04, 0.26, 3.333, 9.99]))
        XCTAssertEqual(percentiles.count, 4)
        XCTAssertEqual(percentiles.p50, 3.3)
        XCTAssertEqual(percentiles.p95, 10.0)
        XCTAssertEqual(percentiles.max, 10.0)
    }
}
