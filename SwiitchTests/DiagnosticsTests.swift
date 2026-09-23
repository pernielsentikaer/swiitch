import AppKit
@testable import Swiitch
import XCTest

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testReportContainsOnlyAllowlistedAggregatesNotWindowOrAppContent() throws {
        let window = WindowInfo(id: 99123, pid: 12345, title: "PRIVATE TITLE https://private.example/token", bounds: .zero, isOnScreen: true)
        let app = AppEntry(pid: 12345, bundleIdentifier: "private.bundle", name: "PRIVATE APP", icon: nil, windows: [window])
        let collection = WindowEnumerator.Collection(apps: [app], duration: 0.123, candidateCount: 2,
            filteredCount: 1, unavailableAXCount: 0, filterReasons: [.orphanedHost: 1])
        let report = DiagnosticsReport.Snapshot(version: "0.1.5-dev", build: "48", osVersion: "macOS test", architecture: "arm64",
            accessibilityGranted: true, screenRecordingGranted: false, keyboardStatus: "ready", loginItemStatus: "disabled",
            automaticUpdateChecks: false,
            discovery: .init(collection: collection, timeoutCount: 1, cacheHits: 2),
            thumbnails: .init(cachedImages: 1, cacheBytes: 2048, pendingWindows: 0, activeBatches: 0,
                              backoffWindows: 0, timedOutBatches: 0, failedCaptures: 0,
                              cacheHits: 12, cacheMisses: 3, cacheEvictions: 1))
        let text = try DiagnosticsReport.render(report)
        for sensitive in ["PRIVATE TITLE", "PRIVATE APP", "private.example", "private.bundle", "99123", "12345", "screenshots", "bounds"] {
            XCTAssertFalse(text.contains(sensitive), sensitive)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "version", "build", "osVersion", "architecture",
            "accessibilityGranted", "screenRecordingGranted", "keyboardStatus", "loginItemStatus",
            "automaticUpdateChecks", "discovery", "thumbnails"])
        XCTAssertEqual(report.discovery.windowCount, 1)
        XCTAssertEqual(report.discovery.lastCollectionMilliseconds, 123)
        let thumbnails = try XCTUnwrap(object["thumbnails"] as? [String: Any])
        XCTAssertEqual(Set(thumbnails.keys), ["cachedImages", "cacheBytes", "pendingWindows", "activeBatches",
            "backoffWindows", "timedOutBatches", "failedCaptures", "cacheHits", "cacheMisses", "cacheEvictions"])
        XCTAssertEqual(thumbnails["cacheHits"] as? Int, 12)
        XCTAssertEqual(thumbnails["cacheMisses"] as? Int, 3)
        XCTAssertEqual(thumbnails["cacheEvictions"] as? Int, 1)
        var written: String?
        XCTAssertNil(written, "Rendering must not write the clipboard")
        XCTAssertTrue(DiagnosticsReport.copy(text, write: { written = $0; return true }))
        XCTAssertEqual(written, text)
        XCTAssertFalse(DiagnosticsReport.copy(text, write: { _ in false }))
    }

    func testUnavailableCollectionIsRepresentedWithoutInventedTiming() {
        let summary = DiagnosticsReport.Discovery(collection: nil, timeoutCount: 2, cacheHits: 0)
        XCTAssertNil(summary.lastCollectionMilliseconds)
        XCTAssertEqual(summary.timeoutCount, 2)
    }

    func testFilteringReasonsExplainRemovedCountsWithoutChangingSelection() {
        let host = WindowInfo(id: 1, pid: 10, title: "", bounds: CGRect(x: 0, y: 400, width: 500, height: 500), isOnScreen: false)
        let document = WindowInfo(id: 2, pid: 10, title: "Private document", bounds: CGRect(x: 100, y: 100, width: 900, height: 700), isOnScreen: true)
        var reasons: [WindowEnumerator.FilterReason: Int] = [:]
        let windows = WindowEnumerator.switchableWindows([host, document], applicationName: "Private app",
            mainDisplayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900), accessibilityWindowIDs: [],
            onFilter: { reasons[$0, default: 0] += $1 })
        XCTAssertEqual(windows.map(\.id), [2])
        XCTAssertEqual(reasons[.orphanedHost], 1)
        XCTAssertEqual(reasons.values.reduce(0, +), 1)
    }
}
