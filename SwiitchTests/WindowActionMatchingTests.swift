import AppKit
@testable import Swiitch
import XCTest

final class WindowActionMatchingTests: XCTestCase {
    private let target = WindowInfo(
        id: 42, pid: 101, title: "Document",
        bounds: CGRect(x: 100, y: 200, width: 900, height: 700), isOnScreen: true
    )

    private func match(_ candidates: [WindowFocuser.CandidateMetadata]) -> Int? {
        WindowFocuser.matchingCandidateIndex(for: target, candidates: candidates, purpose: .windowAction)
    }

    func testStaleActionDoesNotTargetSoleRemainingDifferentWindow() {
        XCTAssertNil(match([.init(windowID: 43, title: "Other document", bounds: target.bounds)]))
    }

    func testKnownDifferentIDIsRejectedEvenWithMatchingTitleAndBounds() {
        XCTAssertNil(match([.init(windowID: 43, title: target.title, bounds: target.bounds)]))
    }

    func testUniqueTitleCannotOverrideKnownDifferentIDAmongSeveralCandidates() {
        XCTAssertNil(match([
            .init(windowID: 43, title: target.title, bounds: target.bounds),
            .init(windowID: 44, title: "Other", bounds: nil),
        ]))
    }

    func testExactIDWinsEvenWhenWindowMovedOrChangedTitle() {
        XCTAssertEqual(match([
            .init(windowID: nil, title: target.title, bounds: target.bounds),
            .init(windowID: target.id, title: "Renamed", bounds: nil),
        ]), 1)
    }

    func testMissingIDRequiresBothTitleAndBounds() {
        XCTAssertNil(match([.init(windowID: nil, title: target.title, bounds: nil)]))
        XCTAssertNil(match([.init(windowID: nil, title: "", bounds: target.bounds)]))
        XCTAssertNil(match([.init(windowID: nil, title: target.title, bounds: .zero)]))
    }

    func testMissingIDCanUseUniqueNormalizedTitleAndMatchingBounds() {
        XCTAssertEqual(match([
            .init(windowID: nil, title: "Other", bounds: target.bounds),
            .init(windowID: nil, title: " document ", bounds: target.bounds.offsetBy(dx: 2, dy: -2)),
        ]), 1)
    }

    func testAmbiguousMissingIDsFailClosed() {
        let candidate = WindowFocuser.CandidateMetadata(windowID: nil, title: target.title, bounds: target.bounds)
        XCTAssertNil(match([candidate, candidate]))
    }

    func testUntitledTargetRequiresExactID() {
        let untitled = WindowInfo(id: 42, pid: 101, title: "", bounds: target.bounds, isOnScreen: true)
        XCTAssertNil(WindowFocuser.matchingCandidateIndex(
            for: untitled, candidates: [.init(windowID: nil, title: "", bounds: target.bounds)], purpose: .windowAction
        ))
        XCTAssertEqual(WindowFocuser.matchingCandidateIndex(
            for: untitled, candidates: [.init(windowID: 42, title: "", bounds: nil)], purpose: .windowAction
        ), 0)
    }

    func testFocusFallbackRemainsSeparateFromWindowControls() {
        let candidates = [WindowFocuser.CandidateMetadata(windowID: 43, title: "Other", bounds: nil)]
        XCTAssertEqual(WindowFocuser.matchingCandidateIndex(for: target, candidates: candidates, purpose: .focus), 0)
        XCTAssertNil(match(candidates))
    }

    func testRestorationRejectsDifferentAndUnavailableIDsEvenWithMatchingMetadata() {
        for id: CGWindowID? in [43, nil] {
            XCTAssertNil(WindowFocuser.matchingCandidateIndex(
                for: target,
                candidates: [.init(windowID: id, title: target.title, bounds: target.bounds)],
                purpose: .restore
            ))
        }
    }

    func testRestorationUsesExactIDWithoutTitleOrGeometry() {
        XCTAssertEqual(WindowFocuser.matchingCandidateIndex(
            for: target,
            candidates: [
                .init(windowID: 43, title: target.title, bounds: target.bounds),
                .init(windowID: 42, title: "", bounds: nil),
            ],
            purpose: .restore
        ), 1)
    }
}
