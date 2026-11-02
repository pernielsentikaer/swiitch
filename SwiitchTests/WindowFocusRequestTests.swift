import AppKit
@testable import Swiitch
import XCTest

final class WindowFocusRequestTests: XCTestCase {
    private func window(_ id: CGWindowID, title: String = "Report") -> WindowInfo {
        .init(id: id, pid: 101, title: title, bounds: .zero, isOnScreen: true)
    }

    func testOneSnapshotAndMemoizedIDsAcrossRetriesAndReassertion() {
        var loads = 0
        var reads: [Int] = []
        let lookup = WindowFocuser.FocusLookup<Int>(budget: .init(now: { 0 }),
            load: { _ in loads += 1; return [1, 2, 3] },
            windowID: { reads.append($0); return CGWindowID($0) },
            title: { _ in "Different" }, bounds: { _ in nil })
        XCTAssertNil(lookup.resolve(window(99)))
        XCTAssertEqual(lookup.resolve(window(2)), 2)
        XCTAssertEqual(lookup.resolve(window(2)), 2)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(reads, [1, 2, 3])
    }

    func testUnavailableMetadataAndFailedSnapshotAreMemoizedToo() {
        var loads = 0
        var idReads = 0
        var titleReads = 0
        var boundsReads = 0
        let lookup = WindowFocuser.FocusLookup<Int>(budget: .init(now: { 0 }),
            load: { _ in loads += 1; return [1, 2] },
            windowID: { _ in idReads += 1; return nil },
            title: { _ in titleReads += 1; return "Report" },
            bounds: { _ in boundsReads += 1; return nil })
        for id: CGWindowID in [99, 100] { XCTAssertNil(lookup.resolve(window(id))) }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(idReads, 2)
        XCTAssertEqual(titleReads, 2)
        XCTAssertEqual(boundsReads, 2)

        let failed = WindowFocuser.FocusLookup<Int>(budget: .init(now: { 0 }),
            load: { _ in loads += 1; return nil }, windowID: { _ in nil },
            title: { _ in "" }, bounds: { _ in nil })
        for id: CGWindowID in [99, 100] { XCTAssertNil(failed.resolve(window(id))) }
        XCTAssertEqual(loads, 2, "A failed bridge is not queried again for every cached window")
    }

    func testSharedBudgetStopsLaterCandidatesAndRejectsLateExactMatch() {
        var clock: TimeInterval = 0
        let budget = WindowFocuser.FocusBudget(seconds: 0.25, now: { clock })
        var loads = 0
        var reads = 0
        let lookup = WindowFocuser.FocusLookup<Int>(budget: budget,
            load: { _ in loads += 1; return [1, 2, 3] },
            windowID: { _ in reads += 1; clock = 0.3; return 42 },
            title: { _ in XCTFail("Expired work cannot read titles"); return "" }, bounds: { _ in nil })
        XCTAssertNil(lookup.resolve(window(42)))
        XCTAssertNil(lookup.resolve(window(43)))
        XCTAssertNil(budget.timeout(maximum: 0.1))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(reads, 1, "Expiry cannot reset for the next target")
    }

    func testBudgetCapsEveryMessagingTimeoutToRemainingTime() throws {
        var clock: TimeInterval = 10
        let budget = WindowFocuser.FocusBudget(seconds: 0.25, now: { clock })
        XCTAssertEqual(try XCTUnwrap(budget.timeout(maximum: 0.03)), 0.03, accuracy: 0.0001)
        clock = 10.24
        XCTAssertEqual(try XCTUnwrap(budget.timeout(maximum: 0.1)), 0.01, accuracy: 0.0001)
        clock = 10.25
        XCTAssertFalse(budget.hasTime)
        XCTAssertNil(budget.timeout(maximum: 0.1))
    }

    func testRestoreNeverReusesTitleFallbackAndNewRequestGetsFreshSnapshot() {
        var calls = 0
        func lookup() -> WindowFocuser.FocusLookup<Int> {
            .init(budget: .init(now: { 0 }), load: { _ in calls += 1; return [1] },
                windowID: { _ in nil }, title: { _ in "Report" }, bounds: { _ in .zero })
        }
        let first = lookup()
        XCTAssertEqual(first.resolve(window(42)), 1)
        XCTAssertNil(first.resolve(window(42), purpose: .restore))
        XCTAssertEqual(lookup().resolve(window(42)), 1)
        XCTAssertEqual(calls, 2)
    }
}
