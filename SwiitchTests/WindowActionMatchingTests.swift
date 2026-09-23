import AppKit
@testable import Swiitch
import XCTest

final class WindowActionMatchingTests: XCTestCase {
    @MainActor
    func testActivationFallbackRequiresUnchangedKnownSourceApp() {
        XCTAssertTrue(WindowFocuser.ActivationRetry.isPending(targetPID: 102, sourcePID: 101, frontmostPID: 101))
        XCTAssertFalse(WindowFocuser.ActivationRetry.isPending(targetPID: 102, sourcePID: 101, frontmostPID: 102))
        XCTAssertFalse(WindowFocuser.ActivationRetry.isPending(targetPID: 102, sourcePID: 101, frontmostPID: 103))
        XCTAssertFalse(WindowFocuser.ActivationRetry.isPending(targetPID: 102, sourcePID: nil, frontmostPID: nil))
        XCTAssertFalse(WindowFocuser.ActivationRetry.isPending(targetPID: 102, sourcePID: nil, frontmostPID: 101))
    }

    @MainActor
    func testLatestActivationRunsAtMostOnceAndChecksNeedAtExecution() {
        let retry = WindowFocuser.ActivationRetry()
        var callbacks: [@MainActor () -> Void] = []
        var needed = true
        var activations = 0
        retry.schedule(ifNeeded: { needed }, action: { activations += 1 }, using: { callbacks.append($0) })
        needed = false
        callbacks[0]()
        XCTAssertEqual(activations, 0, "An activation which succeeded during the delay must not be repeated")
        needed = true
        callbacks[0]()
        XCTAssertEqual(activations, 0, "A consumed callback cannot be revived")
        retry.schedule(ifNeeded: { needed }, action: { activations += 1 }, using: { callbacks.append($0) })
        callbacks[1]()
        callbacks[1]()
        XCTAssertEqual(activations, 1, "The latest still-needed fallback must remain available, once only")
    }

    @MainActor
    func testReleasedActivationCoordinatorDropsQueuedCallback() {
        var retry: WindowFocuser.ActivationRetry? = .init()
        var callback: (@MainActor () -> Void)?
        var activations = 0
        retry?.schedule(ifNeeded: { true }, action: { activations += 1 }, using: { callback = $0 })
        retry = nil
        callback?()
        XCTAssertEqual(activations, 0)
    }

    @MainActor
    func testFocusWindowReportsWhenIdentityCannotBeVerified() {
        // `focus(app:)` relies on this result to fall through to the next cached window or
        // plain app activation instead of silently doing nothing for a stale snapshot.
        let invalid = WindowInfo(id: 0, pid: -1, title: "", bounds: .zero, isOnScreen: false)
        XCTAssertFalse(WindowFocuser.focus(window: invalid))
        let unknownID = WindowInfo(id: .max, pid: ProcessInfo.processInfo.processIdentifier,
                                   title: "", bounds: .zero, isOnScreen: false)
        XCTAssertFalse(WindowFocuser.focus(window: unknownID), "A window ID WindowServer does not know must fail closed")
    }

    @MainActor
    func testEveryNativeFocusEntryCancelsRetryEvenWhenNewTargetIsInvalid() {
        let invalid = WindowInfo(id: 0, pid: -1, title: "", bounds: .zero, isOnScreen: false)
        let requests: [() -> Void] = [
            { WindowFocuser.focus(window: invalid) },
            { WindowFocuser.focus(pid: -1) },
            { WindowFocuser.focus(app: .init(pid: -1, bundleIdentifier: nil, name: "", icon: nil, windows: [])) },
            { _ = WindowFocuser.restoreFocus(pid: -1, windowID: 0) },
        ]
        for request in requests {
            var callback: (@MainActor () -> Void)?
            var activations = 0
            WindowFocuser.activationRetry.schedule(ifNeeded: { true }, action: { activations += 1 }, using: { callback = $0 })
            request()
            callback?()
            XCTAssertEqual(activations, 0, "Validation failures must not leave an older native focus retry alive")
        }
    }

    @MainActor
    func testDelayedActivationCannotOverrideNewerRequest() {
        let retry = WindowFocuser.ActivationRetry()
        var callbacks: [@MainActor () -> Void] = []
        var activated: [Int] = []
        retry.schedule(ifNeeded: { true }, action: { activated.append(1) }, using: { callbacks.append($0) })
        retry.schedule(ifNeeded: { true }, action: { activated.append(2) }, using: { callbacks.append($0) })
        callbacks[1]()
        callbacks[0]()
        XCTAssertEqual(activated, [2], "An old retry must not bring its app back over the newer target")
    }

    @MainActor
    func testCancellationWithoutAnotherActivationInvalidatesRetry() {
        let retry = WindowFocuser.ActivationRetry()
        var callback: (@MainActor () -> Void)?
        var activations = 0
        retry.schedule(ifNeeded: { true }, action: { activations += 1 }, using: { callback = $0 })
        retry.cancel()
        callback?()
        XCTAssertEqual(activations, 0, "Restoring an already-active app must not require another activation")
    }

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
