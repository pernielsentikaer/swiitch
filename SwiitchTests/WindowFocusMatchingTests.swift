import AppKit
@testable import Swiitch
import XCTest

final class WindowFocusMatchingTests: XCTestCase {
    private let target = WindowInfo(id: 42, pid: 101, title: "Report",
                                    bounds: CGRect(x: 20, y: 30, width: 800, height: 600), isOnScreen: true)

    func testExactIDStopsBeforeRemainingIDsAndAllMetadata() {
        var reads: [Int] = []
        let index = WindowFocuser.matchingFocusCandidateIndex(
            for: target, count: 100,
            windowID: { reads.append($0); return $0 == 2 ? 42 : nil },
            title: { _ in XCTFail("Exact identity needs no title"); return "" },
            bounds: { _ in XCTFail("Exact identity needs no geometry"); return nil }, hasTime: { true }
        )
        XCTAssertEqual(index, 2)
        XCTAssertEqual(reads, [0, 1, 2])
    }

    func testUniqueTitleDoesNotReadGeometry() {
        let index = WindowFocuser.matchingFocusCandidateIndex(
            for: target, count: 3, windowID: { _ in nil },
            title: { $0 == 1 ? "  RÉPORT  " : "Other" },
            bounds: { _ in XCTFail("Unique title needs no geometry"); return nil }, hasTime: { true }
        )
        XCTAssertEqual(index, 1)
    }

    func testOnlyAmbiguousTitleMatchesNeedGeometry() {
        var boundsReads: [Int] = []
        let index = WindowFocuser.matchingFocusCandidateIndex(
            for: target, count: 4, windowID: { _ in nil },
            title: { $0 == 1 || $0 == 3 ? "Report" : "Other" },
            bounds: { boundsReads.append($0); return $0 == 3 ? self.target.bounds : .zero }, hasTime: { true }
        )
        XCTAssertEqual(index, 3)
        XCTAssertEqual(boundsReads, [1, 3])
    }

    func testAmbiguousTitleAndBoundsFailClosed() {
        let index = WindowFocuser.matchingFocusCandidateIndex(
            for: target, count: 2, windowID: { _ in nil }, title: { _ in "Report" },
            bounds: { _ in self.target.bounds }, hasTime: { true }
        )
        XCTAssertNil(index)
    }

    func testRestoreNeverUsesSingleWindowOrMetadataFallback() {
        let index = WindowFocuser.matchingFocusCandidateIndex(
            for: target, count: 1, purpose: .restore, windowID: { _ in 99 },
            title: { _ in XCTFail("Restore requires exact identity"); return "Report" },
            bounds: { _ in XCTFail("Restore requires exact identity"); return self.target.bounds }, hasTime: { true }
        )
        XCTAssertNil(index)
    }

    func testSingleWindowFocusFallbackNeedsNoMetadata() {
        let index = WindowFocuser.matchingFocusCandidateIndex(
            for: target, count: 1, windowID: { _ in nil },
            title: { _ in XCTFail("Single-window focus fallback needs no title"); return "" },
            bounds: { _ in XCTFail("Single-window focus fallback needs no geometry"); return nil }, hasTime: { true }
        )
        XCTAssertEqual(index, 0)
    }

    func testSlowIDReadStopsBeforeScanningOtherWindows() {
        var remaining = true
        var reads = 0
        let index = WindowFocuser.matchingFocusCandidateIndex(
            for: target, count: 100,
            windowID: { _ in reads += 1; remaining = false; return nil },
            title: { _ in XCTFail("Expired ID scan must not fall back"); return "" },
            bounds: { _ in XCTFail("Expired ID scan must not fall back"); return nil }, hasTime: { remaining }
        )
        XCTAssertNil(index)
        XCTAssertEqual(reads, 1)
    }

    func testExpiredMetadataReadCannotProduceFalseUniqueMatch() {
        for expireDuringBounds in [false, true] {
            var remaining = true
            let index = WindowFocuser.matchingFocusCandidateIndex(
                for: target, count: 2, windowID: { _ in nil },
                title: { _ in
                    if !expireDuringBounds { remaining = false }
                    return "Report"
                },
                bounds: { _ in remaining = false; return self.target.bounds }, hasTime: { remaining }
            )
            XCTAssertNil(index, "A partial scan cannot establish a unique fallback")
        }
    }
}
