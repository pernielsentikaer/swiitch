@testable import Swiitch
import XCTest

final class IssueReportTests: XCTestCase {
    private func body(of url: URL) throws -> String {
        try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "body" })?.value)
    }

    func testIssueLinkCarriesTheReportFoldedUnderTheDescription() throws {
        let diagnostics = "{\n  \"version\": \"0.1.15\",\n  \"note\": \"a&b=c+d #1 100% æøå\"\n}"
        let prepared = try XCTUnwrap(IssueReport.prepare(diagnostics: diagnostics))
        XCTAssertTrue(prepared.includesDiagnostics)
        XCTAssertTrue(prepared.url.absoluteString.hasPrefix(
            "https://github.com/pernielsentikaer/swiitch/issues/new?template=bug_report.md&body="))
        let body = try body(of: prepared.url)
        XCTAssertTrue(body.hasPrefix("## What happened?"), "The template's sections come first")
        XCTAssertTrue(body.contains("## Diagnostics\n<details>"), "The report is folded away under the description")
        XCTAssertTrue(body.contains("```json\n" + diagnostics + "\n```"), "Query syntax inside the report survives the trip")
        let encodedBody = try XCTUnwrap(prepared.url.query?.components(separatedBy: "&body=").last)
        for forbidden in ["&", "+", "=", "#", " ", "\n"] {
            XCTAssertFalse(encodedBody.contains(forbidden), "'\(forbidden)' must be percent-encoded")
        }
        XCTAssertTrue(encodedBody.unicodeScalars.allSatisfy { $0.isASCII })
    }

    func testAnOversizedReportFallsBackToTheClipboardWording() throws {
        let diagnostics = String(repeating: "x", count: 9_000)
        let prepared = try XCTUnwrap(IssueReport.prepare(diagnostics: diagnostics))
        XCTAssertFalse(prepared.includesDiagnostics)
        XCTAssertLessThanOrEqual(prepared.url.absoluteString.count, IssueReport.maximumURLLength)
        let body = try body(of: prepared.url)
        XCTAssertTrue(body.contains("on your clipboard"))
        XCTAssertFalse(body.contains("xxxx"))
    }

    func testAFullReportFitsInTheLinkWithRoomToSpare() async throws {
        // A live cache's statistics, so the field list follows the type rather than this test.
        let thumbnails = await WindowThumbnails(captureProvider: { _, _ in }).statistics
        let app = AppEntry(pid: 1, bundleIdentifier: "private.bundle", name: "PRIVATE APP", icon: nil, windows: (1...40).map {
            WindowInfo(id: CGWindowID($0), pid: 1, title: "PRIVATE TITLE", bounds: .zero, isOnScreen: true)
        })
        let collection = WindowEnumerator.Collection(apps: [app], duration: 0.123, candidateCount: 90,
            filteredCount: 50, unavailableAXCount: 2, reusedAXCount: 1,
            filterReasons: Dictionary(uniqueKeysWithValues: WindowEnumerator.FilterReason.allCases.map { ($0, 3) }),
            accessibilityMemory: [1: .init(windowIDs: [1], observedWindowIDs: [1, 2], recordedAt: 0)])
        let snapshot = DiagnosticsReport.Snapshot(version: "0.1.15", build: "70", osVersion: "Version 15.1 (Build 24B83)",
            architecture: "arm64", accessibilityGranted: true, screenRecordingGranted: true, keyboardStatus: "ready",
            loginItemStatus: "enabled", automaticUpdateChecks: true,
            discovery: .init(collection: collection, timeoutCount: 12, cacheHits: 3_456,
                             recentDurations: (0..<50).map { 0.010 + Double($0) * 0.003 }),
            thumbnails: thumbnails,
            timing: .init(opens: 1_234, shownOpens: 1_000, hotkeyToSnapshotMs: .init((0..<50).map { Double($0) }),
                          hotkeyToArmedMs: .init((0..<50).map { Double($0) }), hotkeyToPanelMs: .init((0..<50).map { Double($0) }),
                          panelToFirstThumbnailMs: .init((0..<50).map { Double($0) }),
                          lastOpen: .init(milliseconds: ["hotkey": 0, "snapshotReady": 1.5, "armed": 2.25,
                                                         "panel": 160.125, "firstThumbnail": 170.5])))
        let report = try DiagnosticsReport.render(snapshot)
        let prepared = try XCTUnwrap(IssueReport.prepare(diagnostics: report))
        XCTAssertTrue(prepared.includesDiagnostics, "A busy report (\(report.count) chars) must still fit in a link")
        XCTAssertLessThan(prepared.url.absoluteString.count, IssueReport.maximumURLLength * 3 / 4,
                          "Leave headroom for longer OS strings and future fields")
    }
}
