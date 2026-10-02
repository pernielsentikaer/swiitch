import AppKit
import ApplicationServices
import CoreGraphics
@testable import Swiitch
import XCTest

final class WindowEnumeratorTests: XCTestCase {
    private let mainDisplayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testIdentityHashPreservesFullSnapshotEquality() {
        let original = WindowInfo(id: 1, pid: 100, title: "Document", bounds: mainDisplayBounds, isOnScreen: true)
        let copy = WindowInfo(id: 1, pid: 100, title: "Document", bounds: mainDisplayBounds, isOnScreen: true)
        let variants = [
            WindowInfo(id: 2, pid: 100, title: "Document", bounds: mainDisplayBounds, isOnScreen: true),
            WindowInfo(id: 1, pid: 101, title: "Document", bounds: mainDisplayBounds, isOnScreen: true),
            WindowInfo(id: 1, pid: 100, title: "Renamed", bounds: mainDisplayBounds, isOnScreen: true),
            WindowInfo(id: 1, pid: 100, title: "Document", bounds: mainDisplayBounds.offsetBy(dx: 1, dy: 0), isOnScreen: true),
            WindowInfo(id: 1, pid: 100, title: "Document", bounds: mainDisplayBounds, isOnScreen: false),
            WindowInfo(id: 1, pid: 100, title: "Document", bounds: mainDisplayBounds, isOnScreen: true, isMinimized: true),
        ]
        XCTAssertEqual(original, copy)
        XCTAssertEqual(original.hashValue, copy.hashValue)
        for variant in variants { XCTAssertNotEqual(original, variant) }
        XCTAssertEqual(Set([original, copy] + variants).count, 7,
                       "Metadata changes must remain distinct even when their stable identity hash is shared")
    }

    func testDefaultHostIsRemovedWhenTheAppHasARealWindow() {
        let host = WindowInfo(
            id: 1,
            pid: 100,
            title: "",
            bounds: CGRect(x: 0, y: 400, width: 500, height: 500),
            isOnScreen: false
        )
        let real = WindowInfo(
            id: 2,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 0, y: 39, width: 1440, height: 861),
            isOnScreen: false
        )

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [host, real],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [real.id])
    }

    func testSoleDefaultSizedUntitledWindowIsKept() {
        let window = WindowInfo(
            id: 1,
            pid: 100,
            title: "",
            bounds: CGRect(x: 0, y: 400, width: 500, height: 500),
            isOnScreen: false
        )

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [window],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [window.id])
    }

    func testOrphanedHostIsRemovedWhenAccessibilityConfirmsNoWindows() {
        // Runtime regression: a running app with no AX windows retained this hidden host.
        let display = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let host = makeWindow(id: 270, title: "", bounds: CGRect(x: 0, y: 829, width: 500, height: 500))

        let result = WindowEnumerator.switchableWindows(
            [host],
            applicationName: "Any Application",
            mainDisplayBounds: display,
            accessibilityWindowIDs: []
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testOrphanedHostIsKeptWhenAccessibilityIsUnavailable() {
        let host = makeWindow(id: 1, title: "", bounds: CGRect(x: 0, y: 400, width: 500, height: 500))

        let result = WindowEnumerator.switchableWindows(
            [host],
            applicationName: "Any Application",
            mainDisplayBounds: mainDisplayBounds,
            accessibilityWindowIDs: nil
        )

        XCTAssertEqual(result.map(\.id), [host.id])
    }

    func testHostLikeSoleWindowIsKeptWhenAccessibilityPublishesWindows() {
        let host = makeWindow(id: 1, title: "", bounds: CGRect(x: 0, y: 400, width: 500, height: 500))

        for publishedIDs in [Set([host.id]), Set([CGWindowID(999)])] {
            let result = WindowEnumerator.switchableWindows(
                [host],
                applicationName: "Any Application",
                mainDisplayBounds: mainDisplayBounds,
                accessibilityWindowIDs: publishedIDs
            )

            XCTAssertEqual(result.map(\.id), [host.id])
        }
    }

    func testConfirmedEmptyAccessibilityDoesNotHideGenuineUntitledOrMinimizedWindows() {
        let windows = [
            makeWindow(id: 1, title: "", bounds: CGRect(x: 0, y: 400, width: 500, height: 500), isOnScreen: true),
            makeWindow(id: 2, title: "", bounds: CGRect(x: 120, y: 120, width: 500, height: 500)),
            makeWindow(id: 3, title: "Document", bounds: CGRect(x: 0, y: 400, width: 500, height: 500)),
        ]

        for window in windows {
            let result = WindowEnumerator.switchableWindows(
                [window],
                applicationName: "Any Application",
                mainDisplayBounds: mainDisplayBounds,
                accessibilityWindowIDs: []
            )

            XCTAssertEqual(result.map(\.id), [window.id])
        }
    }

    func testAllOrphanedHostsAreRemovedWhenAccessibilityConfirmsNoWindows() {
        let hosts = [1, 2].map {
            makeWindow(id: CGWindowID($0), title: "", bounds: CGRect(x: 0, y: 400, width: 500, height: 500))
        }

        let result = WindowEnumerator.switchableWindows(
            hosts,
            applicationName: "Any Application",
            mainDisplayBounds: mainDisplayBounds,
            accessibilityWindowIDs: []
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testVisibleDefaultSizedUntitledWindowIsKept() {
        let visible = WindowInfo(
            id: 1,
            pid: 100,
            title: "",
            bounds: CGRect(x: 0, y: 400, width: 500, height: 500),
            isOnScreen: true
        )
        let sibling = WindowInfo(
            id: 2,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 100, y: 100, width: 900, height: 700),
            isOnScreen: true
        )

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [visible, sibling],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [visible.id, sibling.id])
    }

    func testNormallyPositionedUntitled500WindowIsKept() {
        let untitled = WindowInfo(
            id: 1,
            pid: 100,
            title: "",
            bounds: CGRect(x: 120, y: 120, width: 500, height: 500),
            isOnScreen: false
        )
        let sibling = WindowInfo(
            id: 2,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 100, y: 100, width: 900, height: 700),
            isOnScreen: false
        )

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [untitled, sibling],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [untitled.id, sibling.id])
    }

    func testAllHostLikeWindowsAreKeptRatherThanMakingTheAppDisappear() {
        let hosts = [1, 2].map { id in
            WindowInfo(
                id: CGWindowID(id),
                pid: 100,
                title: "",
                bounds: CGRect(x: 0, y: 400, width: 500, height: 500),
                isOnScreen: false
            )
        }

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            hosts,
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), hosts.map(\.id))
    }

    func testAccessibilityAuxiliaryOverlaysAreDroppedBesideTheRealWindow() {
        // From a real census of CleanMyMac: one standard window plus its animated scan orb
        // (one layer exposed as a button), an untitled AXUnknown twin, and a small untitled
        // dialog badge. All four are on screen, on the current Space, and AX-published.
        let main = WindowInfo(id: 266, pid: 9343, title: "CleanMyMac", bounds: CGRect(x: 428, y: 173, width: 1200, height: 720), isOnScreen: true)
        let orb = WindowInfo(id: 267, pid: 9343, title: "", bounds: CGRect(x: 942, y: 749, width: 256, height: 256), isOnScreen: true)
        let button = WindowInfo(id: 264, pid: 9343, title: "", bounds: CGRect(x: 942, y: 749, width: 256, height: 256), isOnScreen: true)
        let badge = WindowInfo(id: 265, pid: 9343, title: "", bounds: CGRect(x: 1350, y: 167, width: 284, height: 68), isOnScreen: true)
        let kinds: [CGWindowID: WindowEnumerator.AccessibilityKind] = [
            267: .init(role: kAXWindowRole, subrole: kAXUnknownSubrole),
            264: .init(role: "AXButton", subrole: kAXUnknownSubrole),
            265: .init(role: kAXWindowRole, subrole: kAXDialogSubrole),
        ]
        let auxiliary = WindowEnumerator.accessibilityAuxiliaryIDs(kinds: kinds, accessibilityTitledIDs: [])
        XCTAssertEqual(auxiliary, [267, 264, 265])

        var reasons: [WindowEnumerator.FilterReason: Int] = [:]
        let kept = WindowEnumerator.switchableWindows(
            [orb, main, badge, button], applicationName: "CleanMyMac", mainDisplayBounds: mainDisplayBounds,
            accessibilityWindowIDs: [266, 267, 264, 265], accessibilityAuxiliaryIDs: auxiliary,
            onFilter: { reasons[$0, default: 0] += $1 }
        )
        XCTAssertEqual(kept.map(\.id), [266])
        XCTAssertEqual(reasons[.accessibilityAuxiliary], 3)
        XCTAssertEqual(reasons[.notPublishedByAX], 0)
    }

    func testAccessibilityAuxiliaryRuleNeedsAnAnchorAndNeverHidesLargerOrMinimizedOrTitledWindows() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let hud = WindowInfo(id: 1, pid: 10, title: "", bounds: CGRect(x: 300, y: 300, width: 200, height: 100), isOnScreen: true)
        let untitledDocument = WindowInfo(id: 2, pid: 10, title: "", bounds: frame, isOnScreen: true)
        let titled = WindowInfo(id: 3, pid: 10, title: "Notes", bounds: frame, isOnScreen: true)
        let bigger = WindowInfo(id: 4, pid: 10, title: "", bounds: frame.insetBy(dx: -50, dy: -50), isOnScreen: true)
        let minimized = WindowInfo(id: 5, pid: 10, title: "", bounds: hud.bounds, isOnScreen: false, isMinimized: true)

        // A sole HUD-like window still represents its app.
        XCTAssertEqual(WindowEnumerator.windowsRemovingAccessibilityAuxiliaries([hud], auxiliaryIDs: [1]).map(\.id), [1])
        // An untitled standard sibling is not an anchor: nothing is dropped without a titled window.
        XCTAssertEqual(WindowEnumerator.windowsRemovingAccessibilityAuxiliaries([hud, untitledDocument], auxiliaryIDs: [1]).map(\.id), [1, 2])
        // With a titled anchor the HUD goes; a non-standard window larger than every anchor stays,
        // and a minimized one is never judged by overlay status.
        XCTAssertEqual(WindowEnumerator.windowsRemovingAccessibilityAuxiliaries(
            [hud, titled, bigger, minimized], auxiliaryIDs: [1, 4, 5]).map(\.id), [3, 4, 5])
        // Non-window roles are auxiliary regardless of title; titled non-standard windows are not.
        let kinds: [CGWindowID: WindowEnumerator.AccessibilityKind] = [
            6: .init(role: "AXButton", subrole: ""),
            7: .init(role: kAXWindowRole, subrole: kAXDialogSubrole),
            8: .init(role: kAXWindowRole, subrole: kAXStandardWindowSubrole),
            9: .init(role: kAXWindowRole, subrole: kAXFloatingWindowSubrole),
        ]
        XCTAssertEqual(WindowEnumerator.accessibilityAuxiliaryIDs(kinds: kinds, accessibilityTitledIDs: [6, 7]), [6, 9])
    }

    func testAuxiliaryFilteringKeepsUntitledDocumentsAndUnavailableMetadata() {
        let main = makeWindow(id: 1, title: "Document", bounds: CGRect(x: 100, y: 100, width: 900, height: 600))
        let untitled = makeWindow(id: 2, title: "", bounds: CGRect(x: 220, y: 200, width: 600, height: 400))
        let metadataCases: [[CGWindowID: WindowEnumerator.AccessibilityKind]] = [
            [:], // Missing or timed-out metadata is not evidence of an overlay.
            [2: .init(role: kAXWindowRole, subrole: "")],
            [2: .init(role: kAXWindowRole, subrole: kAXStandardWindowSubrole)],
        ]
        for kinds in metadataCases {
            let auxiliary = WindowEnumerator.accessibilityAuxiliaryIDs(kinds: kinds, accessibilityTitledIDs: [])
            let kept = WindowEnumerator.switchableWindows(
                [untitled, main], applicationName: "Example", mainDisplayBounds: mainDisplayBounds,
                accessibilityWindowIDs: [1, 2], accessibilityAuxiliaryIDs: auxiliary
            )
            XCTAssertEqual(kept.map(\.id), [2, 1])
        }
    }

    func testRememberedAccessibilityReadCoversAFailedReadWithoutHidingNewOrVisibleWindows() {
        let frame = CGRect(x: 100, y: 100, width: 900, height: 600)
        let real = WindowInfo(id: 1, pid: 300, title: "Scan", bounds: frame, isOnScreen: true)
        let ghostA = WindowInfo(id: 2, pid: 300, title: "", bounds: frame.insetBy(dx: 40, dy: 20), isOnScreen: false)
        let ghostB = WindowInfo(id: 3, pid: 300, title: "", bounds: frame.insetBy(dx: 300, dy: 200), isOnScreen: false)
        // Created after the remembered read: unknown to it, so it must be kept.
        let newer = WindowInfo(id: 4, pid: 300, title: "", bounds: frame.offsetBy(dx: 50, dy: 50), isOnScreen: false)
        // Was a ghost at the remembered read but is visibly on screen now: keep it too.
        let reshown = WindowInfo(id: 5, pid: 300, title: "", bounds: frame.offsetBy(dx: 80, dy: 80), isOnScreen: true)
        let memory = WindowEnumerator.AccessibilityMemory(windowIDs: [1], observedWindowIDs: [1, 2, 3, 5], recordedAt: 0)

        // A fresh read always wins, including a confirmed-empty list.
        var evidence = WindowEnumerator.accessibilityEvidence(fresh: [1, 2], memory: memory)
        XCTAssertEqual(evidence.ids, [1, 2]); XCTAssertNil(evidence.observed); XCTAssertFalse(evidence.reused)
        evidence = WindowEnumerator.accessibilityEvidence(fresh: [], memory: memory)
        XCTAssertEqual(evidence.ids, []); XCTAssertFalse(evidence.reused)

        // A failed read falls back to memory, scoped to what that read observed.
        evidence = WindowEnumerator.accessibilityEvidence(fresh: nil, memory: memory)
        XCTAssertEqual(evidence.ids, [1]); XCTAssertEqual(evidence.observed, [1, 2, 3, 5]); XCTAssertTrue(evidence.reused)
        let kept = WindowEnumerator.windowsMatchingAccessibility(
            [real, ghostA, ghostB, newer, reshown], axWindowIDs: evidence.ids, observedWindowIDs: evidence.observed
        )
        XCTAssertEqual(kept.map(\.id), [1, 4, 5], "Remembered ghosts drop; a newer window and a now-visible one stay")

        // No memory and no fresh read: keep everything, as before.
        evidence = WindowEnumerator.accessibilityEvidence(fresh: nil, memory: nil)
        XCTAssertNil(evidence.ids); XCTAssertFalse(evidence.reused)
        // An empty memory is never evidence.
        let empty = WindowEnumerator.AccessibilityMemory(windowIDs: [], observedWindowIDs: [1], recordedAt: 0)
        XCTAssertNil(WindowEnumerator.accessibilityEvidence(fresh: nil, memory: empty).ids)
    }

    func testAccessibilityIntersectionDropsUnpublishedHelperWindow() {
        let real = WindowInfo(
            id: 5097,
            pid: 200,
            title: "Workspace",
            bounds: CGRect(x: 0, y: 39, width: 2056, height: 1254),
            isOnScreen: true
        )
        let helper = WindowInfo(
            id: 5099,
            pid: 200,
            title: "",
            bounds: CGRect(x: 0, y: 1192, width: 500, height: 500),
            isOnScreen: false
        )

        let result = WindowEnumerator.windowsMatchingAccessibility(
            [real, helper],
            axWindowIDs: [real.id]
        )

        XCTAssertEqual(result.map(\.id), [real.id])
    }

    func testEveryAppSurvivesTemporaryTotalAccessibilityIDMismatch() {
        let windows = [
            WindowInfo(
                id: 480,
                pid: 201,
                title: "First",
                bounds: CGRect(x: 0, y: 39, width: 2056, height: 1254),
                isOnScreen: true
            ),
            WindowInfo(
                id: 481,
                pid: 201,
                title: "Second",
                bounds: CGRect(x: 0, y: 39, width: 2056, height: 1254),
                isOnScreen: true
            ),
        ]

        let result = WindowEnumerator.windowsMatchingAccessibility(
            windows,
            axWindowIDs: [999]
        )

        XCTAssertEqual(result.map(\.id), windows.map(\.id))
    }

    func testStaleAccessibilityPublishingOnlyAHostCannotReplaceTheRealSibling() {
        let host = makeWindow(
            id: 1,
            title: "",
            bounds: CGRect(x: 0, y: 400, width: 500, height: 500),
            isOnScreen: false
        )
        let real = makeWindow(
            id: 2,
            title: "Workspace",
            bounds: CGRect(x: 40, y: 30, width: 1200, height: 800),
            isOnScreen: true
        )

        let result = WindowEnumerator.switchableWindows(
            [host, real],
            applicationName: "Unknown Application",
            mainDisplayBounds: mainDisplayBounds,
            accessibilityWindowIDs: [host.id]
        )

        XCTAssertEqual(result.map(\.id), [real.id])
    }

    func testUntitledSameFrameDuplicateIsRemovedWithoutKnowingTheApp() {
        let shadow = makeWindow(id: 1, title: "", bounds: CGRect(x: 80, y: 70, width: 900, height: 700))
        let real = makeWindow(id: 2, title: "Workspace", bounds: shadow.bounds)

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [shadow, real],
            applicationName: "Unseen Application",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [real.id])
    }

    func testTwoTitledWindowsWithTheSameFrameAreBothKept() {
        let first = makeWindow(id: 1, title: "First", bounds: CGRect(x: 80, y: 70, width: 900, height: 700))
        let second = makeWindow(id: 2, title: "Second", bounds: first.bounds)

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [first, second],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    func testUntitledCenteredWrapperIsRemovedWithoutAnIdentifierRule() {
        let real = makeWindow(
            id: 1,
            title: "Workspace",
            bounds: CGRect(x: 0, y: 39, width: 1200, height: 800),
            isOnScreen: true
        )
        let shadow = makeWindow(
            id: 2,
            title: "",
            bounds: CGRect(x: -79, y: -40, width: 1358, height: 958),
            isOnScreen: true
        )

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [shadow, real],
            applicationName: "Unknown Browser",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [real.id])
    }

    func testUntitledExtremeAspectStripIsRemovedBesideARealWindow() {
        let strip = makeWindow(id: 1, title: "", bounds: CGRect(x: 0, y: 0, width: 1200, height: 90))
        let real = makeWindow(id: 2, title: "Workspace", bounds: CGRect(x: 0, y: 39, width: 1200, height: 800))

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [strip, real],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [real.id])
    }

    func testTitledExtremeAspectWindowIsKept() {
        let palette = makeWindow(id: 1, title: "Timeline", bounds: CGRect(x: 0, y: 0, width: 1200, height: 90))
        let real = makeWindow(id: 2, title: "Workspace", bounds: CGRect(x: 0, y: 100, width: 1200, height: 800))

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [palette, real],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [palette.id, real.id])
    }

    func testHiddenOwnerNamedDefaultPlaceholderIsRemoved() {
        let placeholder = makeWindow(
            id: 1,
            title: "Example",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: false
        )
        let document = makeWindow(
            id: 2,
            title: "Project",
            bounds: CGRect(x: 40, y: 30, width: 1200, height: 800),
            isOnScreen: true
        )

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [placeholder, document],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [document.id])
    }

    func testVisibleOwnerNamedDefaultWindowIsKept() {
        let main = makeWindow(
            id: 1,
            title: "Example",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true
        )
        let document = makeWindow(id: 2, title: "Project", bounds: CGRect(x: 40, y: 30, width: 1200, height: 800))

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [main, document],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [main.id, document.id])
    }

    func testRepeatedCompactWindowsAreNotRemovedBySizeOrTitleAlone() {
        let document = makeWindow(id: 1, title: "Document", bounds: CGRect(x: 60, y: 40, width: 1300, height: 800))
        let utilityOne = makeWindow(id: 2, title: "Controls", bounds: CGRect(x: 900, y: 500, width: 332, height: 286))
        let utilityTwo = makeWindow(id: 3, title: "Preview", bounds: CGRect(x: 550, y: 500, width: 332, height: 286))

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [document, utilityOne, utilityTwo],
            applicationName: "Any Application",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [document.id, utilityOne.id, utilityTwo.id])
    }

    func testSingleCompactSecondaryWindowIsKept() {
        let document = makeWindow(id: 1, title: "Document", bounds: CGRect(x: 60, y: 40, width: 1300, height: 800))
        let utility = makeWindow(id: 2, title: "Inspector", bounds: CGRect(x: 900, y: 500, width: 332, height: 286))

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [document, utility],
            applicationName: "Example",
            mainDisplayBounds: mainDisplayBounds
        )

        XCTAssertEqual(result.map(\.id), [document.id, utility.id])
    }

    func testSameSizedCompactWindowsAreKeptWithoutALargerSibling() {
        let first = makeWindow(id: 1, title: "First", bounds: CGRect(x: 50, y: 50, width: 332, height: 286))
        let second = makeWindow(id: 2, title: "Second", bounds: CGRect(x: 450, y: 50, width: 332, height: 286))

        let result = WindowEnumerator.windowsRemovingNonUserSurfaces(
            [first, second], applicationName: "Notes", mainDisplayBounds: mainDisplayBounds
        )
        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    func testAccessibilityPublishedCompactDocumentsSurviveBesideLargeWindow() {
        for visible in [true, false] {
            let windows = compactDocumentWindows(isOnScreen: visible)
            let result = WindowEnumerator.switchableWindows(
                windows, applicationName: "Notes", mainDisplayBounds: mainDisplayBounds,
                accessibilityWindowIDs: [1, 2, 3]
            )
            XCTAssertEqual(result.map(\.id), [1, 2, 3])
        }
    }

    func testCompactDocumentsSurviveUnavailableEmptyOrMismatchedAccessibility() {
        for ids: Set<CGWindowID>? in [nil, [], [99]] {
            let result = WindowEnumerator.switchableWindows(
                compactDocumentWindows(isOnScreen: true), applicationName: "Notes",
                mainDisplayBounds: mainDisplayBounds, accessibilityWindowIDs: ids
            )
            XCTAssertEqual(result.map(\.id), [1, 2, 3])
        }
    }

    func testAccessibilityEvidenceStillRemovesUnpublishedCompactHelpers() {
        let windows = compactDocumentWindows(isOnScreen: true)
        for ids: Set<CGWindowID> in [[1], [1, 2]] {
            let result = WindowEnumerator.switchableWindows(
                windows, applicationName: "Notes", mainDisplayBounds: mainDisplayBounds,
                accessibilityWindowIDs: ids
            )
            XCTAssertEqual(Set(result.map(\.id)), ids)
        }
    }

    func testUntitledCompactWindowsAreNotRemovedBySizeAlone() {
        let windows = compactDocumentWindows(isOnScreen: true).map {
            WindowInfo(id: $0.id, pid: $0.pid, title: "", bounds: $0.bounds, isOnScreen: $0.isOnScreen)
        }
        let result = WindowEnumerator.switchableWindows(
            windows, applicationName: "Notes", mainDisplayBounds: mainDisplayBounds,
            accessibilityWindowIDs: [1, 2, 3]
        )
        XCTAssertEqual(result.map(\.id), [1, 2, 3])
    }

    private func compactDocumentWindows(isOnScreen: Bool) -> [WindowInfo] {
        [
            makeWindow(id: 1, title: "Document", bounds: CGRect(x: 50, y: 50, width: 900, height: 700), isOnScreen: isOnScreen),
            makeWindow(id: 2, title: "Note One", bounds: CGRect(x: 100, y: 100, width: 300, height: 200), isOnScreen: isOnScreen),
            makeWindow(id: 3, title: "Note Two", bounds: CGRect(x: 500, y: 100, width: 300, height: 200), isOnScreen: isOnScreen),
        ]
    }

    private func makeWindow(
        id: CGWindowID,
        title: String,
        bounds: CGRect,
        isOnScreen: Bool = false
    ) -> WindowInfo {
        WindowInfo(id: id, pid: 100, title: title, bounds: bounds, isOnScreen: isOnScreen)
    }
}

final class AXPrivateTests: XCTestCase {
    func testElementsReadsAccessibilityElementsFromFoundationArray() {
        let first = AXUIElementCreateApplication(101)
        let second = AXUIElementCreateApplication(102)
        let value = NSArray(array: [first, second])

        XCTAssertEqual(AXPrivate.elements(from: value).count, 2)
    }

    func testElementsRejectsNonArrayValue() {
        XCTAssertTrue(AXPrivate.elements(from: "not an array" as NSString).isEmpty)
    }
}

@available(macOS 14.0, *)
final class WindowThumbnailsTests: XCTestCase {
    func testConcurrentRequestsAwaitOneSharedCapture() async {
        let controller = BlockingThumbnailCapture()
        let thumbnails = WindowThumbnails(captureProvider: { windowIDs, deliver in
            await controller.capture(windowIDs: windowIDs, deliver: deliver)
        })

        let first = Task { await thumbnails.images(for: [42]) }
        await controller.waitUntilStarted()
        let second = Task { await thumbnails.images(for: [42]) }
        await Task.yield()
        await controller.release()

        let firstResult = await first.value
        let secondResult = await second.value
        let captureCount = await controller.captureCount
        XCTAssertNotNil(firstResult[42])
        XCTAssertNotNil(secondResult[42])
        XCTAssertEqual(captureCount, 1)
    }

    func testProgressHandlerReceivesFirstImageBeforeBatchCompletes() async throws {
        let controller = ProgressiveThumbnailCapture()
        let recorder = await MainActor.run { ThumbnailProgressRecorder() }
        let thumbnails = WindowThumbnails(captureProvider: { windowIDs, deliver in
            await controller.capture(windowIDs: windowIDs, deliver: deliver)
        })

        let request = Task {
            await thumbnails.images(for: [1, 2]) { windowID, _ in
                recorder.ids.append(windowID)
            }
        }
        await controller.waitUntilFirstDelivery()

        await waitUntil("the first delivery to land") { recorder.ids == [1] }
        let partialIDs = await MainActor.run { recorder.ids }
        XCTAssertEqual(partialIDs, [1])

        await controller.releaseSecondDelivery()
        let result = await request.value
        let finalIDs = await MainActor.run { recorder.ids }
        XCTAssertEqual(Set(result.keys), Set([1, 2]))
        XCTAssertEqual(finalIDs, [1, 2])
    }

    func testCancellingPrewarmLetsForegroundStartFreshCapture() async {
        let controller = CancellableThumbnailCapture()
        let thumbnails = WindowThumbnails(captureProvider: { windowIDs, deliver in
            await controller.capture(windowIDs: windowIDs, deliver: deliver)
        })

        let prewarm = Task { await thumbnails.images(for: [7]) }
        await controller.waitUntilFirstStarted()
        await thumbnails.cancelPendingCaptures()
        let foreground = await thumbnails.images(for: [7])
        let prewarmResult = await prewarm.value
        let captureCount = await controller.captureCount

        XCTAssertTrue(prewarmResult.isEmpty)
        XCTAssertNotNil(foreground[7])
        XCTAssertEqual(captureCount, 2)
    }
}

@available(macOS 14.0, *)
private actor BlockingThumbnailCapture {
    private(set) var captureCount = 0
    private var isStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func capture(windowIDs: [CGWindowID], deliver: ThumbnailCaptureDelivery) async {
        captureCount += 1
        isStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        let image = thumbnailFixture(size: NSSize(width: 32, height: 24))
        for windowID in windowIDs {
            await deliver(windowID, image)
        }
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

@available(macOS 14.0, *)
private actor ProgressiveThumbnailCapture {
    private var didDeliverFirst = false
    private var canDeliverSecond = false
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondWaiters: [CheckedContinuation<Void, Never>] = []

    func capture(windowIDs: [CGWindowID], deliver: ThumbnailCaptureDelivery) async {
        guard let first = windowIDs.first else { return }
        let image = thumbnailFixture(size: NSSize(width: 32, height: 24))
        await deliver(first, image)
        didDeliverFirst = true
        firstWaiters.forEach { $0.resume() }
        firstWaiters.removeAll()

        if !canDeliverSecond {
            await withCheckedContinuation { continuation in
                secondWaiters.append(continuation)
            }
        }
        for windowID in windowIDs.dropFirst() {
            await deliver(windowID, image)
        }
    }

    func waitUntilFirstDelivery() async {
        if didDeliverFirst { return }
        await withCheckedContinuation { continuation in
            firstWaiters.append(continuation)
        }
    }

    func releaseSecondDelivery() {
        canDeliverSecond = true
        secondWaiters.forEach { $0.resume() }
        secondWaiters.removeAll()
    }
}

@available(macOS 14.0, *)
private actor CancellableThumbnailCapture {
    private(set) var captureCount = 0
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func capture(windowIDs: [CGWindowID], deliver: ThumbnailCaptureDelivery) async {
        captureCount += 1
        let requestNumber = captureCount
        if requestNumber == 1 {
            firstStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return
        }

        let image = thumbnailFixture(size: NSSize(width: 32, height: 24))
        for windowID in windowIDs {
            await deliver(windowID, image)
        }
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

@MainActor
@available(macOS 14.0, *)
private final class ThumbnailProgressRecorder {
    var ids: [CGWindowID] = []
}

final class WindowFocuserMatchingTests: XCTestCase {
    private let target = WindowInfo(
        id: 42,
        pid: 100,
        title: "Document",
        bounds: CGRect(x: 100, y: 200, width: 900, height: 700),
        isOnScreen: true
    )

    func testExactWindowIDWinsOverFallbackMetadata() {
        let candidates = [
            WindowFocuser.CandidateMetadata(windowID: 41, title: "Document", bounds: target.bounds),
            WindowFocuser.CandidateMetadata(windowID: 42, title: "Other", bounds: nil),
        ]

        XCTAssertEqual(WindowFocuser.matchingCandidateIndex(for: target, candidates: candidates), 1)
    }

    func testUniqueNormalizedTitleCanResolveMissingPrivateID() {
        let candidates = [
            WindowFocuser.CandidateMetadata(windowID: nil, title: "Other", bounds: nil),
            WindowFocuser.CandidateMetadata(windowID: nil, title: " document ", bounds: nil),
        ]

        XCTAssertEqual(WindowFocuser.matchingCandidateIndex(for: target, candidates: candidates), 1)
    }

    func testDuplicateTitleRequiresOneUniqueBoundsMatch() {
        let candidates = [
            WindowFocuser.CandidateMetadata(
                windowID: nil,
                title: "Document",
                bounds: CGRect(x: 400, y: 300, width: 900, height: 700)
            ),
            WindowFocuser.CandidateMetadata(
                windowID: nil,
                title: "Document",
                bounds: CGRect(x: 103, y: 197, width: 899, height: 701)
            ),
        ]

        XCTAssertEqual(WindowFocuser.matchingCandidateIndex(for: target, candidates: candidates), 1)
    }

    func testAmbiguousDuplicateTitleFailsClosed() {
        let candidates = [
            WindowFocuser.CandidateMetadata(windowID: nil, title: "Document", bounds: nil),
            WindowFocuser.CandidateMetadata(windowID: nil, title: "Document", bounds: nil),
        ]

        XCTAssertNil(WindowFocuser.matchingCandidateIndex(for: target, candidates: candidates))
    }
}
