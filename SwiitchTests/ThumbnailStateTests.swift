import AppKit
import SwiftUI
@testable import Swiitch
import XCTest

@MainActor
final class ThumbnailStateTests: XCTestCase {
    func testRefreshFollowsViewportAndSearchInEveryWindowMode() async throws {
        for mode in [SwitcherModel.Mode.flatWindows, .currentAppWindows, .windowsForApp] {
            let fixture = CaptureModelFixture(returnImages: true, windowCount: 4,
                displayMode: mode == .windowsForApp ? .apps : .windows, frontmostPID: 101)
            defer { fixture.close() }
            if mode == .currentAppWindows { fixture.model.armForCurrentApp(reverse: false) }
            else { fixture.model.arm(reverse: false) }
            if mode == .windowsForApp { fixture.model.enterWindowMode() }
            try await eventually { fixture.model.thumbnails.count == 4 }
            fixture.model.mouseHasMoved = true
            if mode == .windowsForApp { fixture.model.selectWindow(at: 0) }
            else { fixture.model.selectFlatWindow(at: 0) }
            fixture.model.updateThumbnailViewport([2], context: fixture.model.thumbnailViewportContext)
            try await eventually { fixture.model.thumbnails[2]?.size.width == 102 }
            await fixture.model.refreshVisibleThumbnails()
            let calls = await fixture.capture.calls
            XCTAssertEqual(Set(try XCTUnwrap(calls.last)), [1, 2], "Visible tiles plus selected target only: \(mode)")
            fixture.model.appendFilter("3")
            await fixture.model.refreshVisibleThumbnails()
            let filtered = await fixture.capture.calls.last
            XCTAssertEqual(filtered, [3], "A filter must exclude hidden windows even before new geometry arrives")
            XCTAssertEqual(fixture.model.thumbnails.count, 4, "Hidden previews remain cached in the presentation")
        }
    }

    func testEmptySearchResultsDoNotCaptureInvisibleSelectedWindow() async throws {
        let fixture = CaptureModelFixture(returnImages: true, windowCount: 4)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await eventually { fixture.model.thumbnails.count == 4 }
        let count = await fixture.capture.calls.count
        fixture.model.appendFilter("missing")
        await fixture.model.refreshVisibleThumbnails()
        let after = await fixture.capture.calls.count
        XCTAssertEqual(after, count)
        XCTAssertTrue(fixture.model.thumbnailRefreshWindows.isEmpty)
        XCTAssertEqual(fixture.model.thumbnails.count, 4)
    }

    func testScrollingLoadsNewlyVisibleTilesWithoutRepeatingUnchangedViewport() async throws {
        let fixture = CaptureModelFixture(returnImages: true, windowCount: 4)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await eventually { fixture.model.thumbnails.count == 4 }
        fixture.model.mouseHasMoved = true
        fixture.model.selectFlatWindow(at: 0)
        let context = fixture.model.thumbnailViewportContext
        fixture.model.updateThumbnailViewport([1], context: context)
        try await eventually { fixture.model.thumbnails[1]?.size.width == 102 }
        fixture.model.updateThumbnailViewport([3], context: context)
        try await eventually { fixture.model.thumbnails[3]?.size.width == 103 }
        fixture.model.updateThumbnailViewport([3], context: context)
        await Task.yield()
        let calls = await fixture.capture.calls
        let fresh = await fixture.capture.freshRequests
        XCTAssertEqual(calls.suffix(2), [[1], [3]])
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(fresh, [false, false, false], "Scroll requests reuse fresh cached images")
        XCTAssertEqual(fixture.model.thumbnails[2]?.size.width, 101)
    }

    func testStaleViewportReportsCannotAffectNewQueryOrInvocation() async throws {
        let fixture = CaptureModelFixture(returnImages: true, windowCount: 4)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await eventually { fixture.model.thumbnails.count == 4 }
        let old = fixture.model.thumbnailViewportContext
        fixture.model.appendFilter("3")
        fixture.model.updateThumbnailViewport([], context: old)
        XCTAssertEqual(fixture.model.thumbnailRefreshWindows.map(\.id), [3])
        fixture.model.cancel()
        fixture.model.arm(reverse: false)
        fixture.model.updateThumbnailViewport([], context: old)
        XCTAssertEqual(fixture.model.thumbnailRefreshWindows.count, 4)
    }

    func testRefreshStopsWithClosedPanelOrRevokedPermission() async throws {
        let fixture = CaptureModelFixture(returnImages: true)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await eventually { fixture.model.thumbnails.count == 2 }
        let count = await fixture.capture.calls.count
        fixture.model.updateScreenCapturePermission(false)
        await fixture.model.refreshVisibleThumbnails()
        fixture.model.cancel()
        await fixture.model.refreshVisibleThumbnails()
        let after = await fixture.capture.calls.count
        XCTAssertEqual(after, count)
    }

    func testViewportGeometryExcludesPrefetchedAndEdgeTouchingCells() {
        let layout = ThumbnailViewportLayout(bounds: CGRect(x: 0, y: 0, width: 200, height: 100), windowFrames: [
            1: CGRect(x: 0, y: 0, width: 80, height: 60),
            2: CGRect(x: -20, y: 80, width: 100, height: 40),
            3: CGRect(x: 0, y: 100, width: 100, height: 40),
            4: CGRect(x: 0, y: -40, width: 100, height: 39),
            5: CGRect(x: 220, y: 0, width: 100, height: 40),
            6: CGRect(x: 0, y: 20, width: 100, height: 0),
        ])
        XCTAssertEqual(layout.visibleWindowIDs, [1, 2])
        XCTAssertTrue(ThumbnailViewportLayout().visibleWindowIDs.isEmpty)
    }

    func testHostedSwitcherReportsActualClippedViewport() async throws {
        let fixture = CaptureModelFixture(returnImages: true, windowCount: 40)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        let host = NSHostingView(rootView: SwitcherView(model: fixture.model).frame(width: 640, height: 340))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 340),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await eventually { fixture.model.thumbnailRefreshWindows.count < 40 }
        XCTAssertGreaterThan(fixture.model.thumbnailRefreshWindows.count, 0)
        XCTAssertLessThan(fixture.model.thumbnailRefreshWindows.count, 40)
        let initialCount = fixture.model.thumbnailRefreshWindows.count
        fixture.model.mouseHasMoved = true
        fixture.model.selectFlatWindow(at: 39)
        try await eventually {
            !fixture.model.thumbnailRefreshWindows.isEmpty &&
                fixture.model.thumbnailRefreshWindows.allSatisfy { $0.id > 20 }
        }
        print("Hosted viewport refresh: initial=\(initialCount), afterScroll=\(fixture.model.thumbnailRefreshWindows.count), total=40")
    }

    func testDeniedPermissionKeepsWindowsSwitchableWithoutCapturing() async throws {
        var focused: CGWindowID?
        let fixture = CaptureModelFixture(granted: false, focus: { focused = $0.id })
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fixture.model.flatWindows.count, 2)
        XCTAssertEqual(fixture.model.thumbnailState(for: 1), .permissionRequired)
        let calls = await fixture.capture.calls.count
        XCTAssertEqual(calls, 0)
        fixture.model.commitWindow(id: 1)
        XCTAssertEqual(focused, 1)
    }

    func testFailedCaptureShowsUnavailableWithoutRemovingWindow() async throws {
        let fixture = CaptureModelFixture()
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await eventually { fixture.model.thumbnailState(for: 1) == .unavailable }
        XCTAssertEqual(fixture.model.flatWindows.map(\.id), [1, 2])
        XCTAssertTrue(fixture.model.isArmed)
    }

    func testLoadingAndProgressReadyStatesBeforeWholeBatchCompletes() async throws {
        let fixture = CaptureModelFixture(blocked: true)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await waitForCalls(1, fixture.capture)
        XCTAssertEqual(fixture.model.thumbnailState(for: 2), .loading)
        await fixture.capture.progress(batch: 1, id: 2)
        XCTAssertEqual(fixture.model.thumbnailState(for: 2), .ready)
        XCTAssertEqual(fixture.model.thumbnailState(for: 1), .loading)
        await fixture.capture.finish(batch: 1)
        try await eventually { fixture.model.thumbnailState(for: 1) == .unavailable }
        XCTAssertEqual(fixture.model.thumbnailState(for: 2), .ready)
    }

    func testRevocationClearsImagesAndRejectsLateResultsThenGrantReloads() async throws {
        let fixture = CaptureModelFixture(blocked: true)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await waitForCalls(1, fixture.capture)
        await fixture.capture.progress(batch: 1, id: 2)
        XCTAssertNotNil(fixture.model.thumbnails[2])
        fixture.model.updateScreenCapturePermission(false)
        XCTAssertTrue(fixture.model.thumbnails.isEmpty)
        XCTAssertEqual(fixture.model.thumbnailState(for: 2), .permissionRequired)
        XCTAssertEqual(fixture.model.flatWindows.count, 2)
        await fixture.capture.progress(batch: 1, id: 1)
        XCTAssertTrue(fixture.model.thumbnails.isEmpty)
        fixture.model.updateScreenCapturePermission(true)
        try await waitForCalls(2, fixture.capture)
        await fixture.capture.finish(batch: 2, imageID: 2)
        try await eventually { fixture.model.thumbnailState(for: 2) == .ready }
        await fixture.capture.progress(batch: 1, id: 2)
        await fixture.capture.finish(batch: 1, imageID: 2)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(fixture.model.thumbnails[2]?.size.width, 102)
        let transitions = await fixture.capture.permissions
        XCTAssertEqual(transitions, [false, true])
    }

    func testRapidPermissionChangesAreSerializedAndOnlyFinalGrantReloads() async throws {
        let fixture = CaptureModelFixture()
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await waitForCalls(1, fixture.capture)
        for allowed in [false, true, false, true] { fixture.model.updateScreenCapturePermission(allowed) }
        try await waitForCalls(2, fixture.capture)
        let transitions = await fixture.capture.permissions
        XCTAssertEqual(transitions, [false, true, false, true])
        let calls = await fixture.capture.calls.count
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(fixture.model.screenCaptureGranted)
    }

    func testClosingPickerRejectsLateProgressAndFinalResult() async throws {
        let fixture = CaptureModelFixture(blocked: true)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await waitForCalls(1, fixture.capture)
        fixture.model.cancel()
        await fixture.capture.progress(batch: 1, id: 2)
        await fixture.capture.finish(batch: 1, imageID: 2)
        XCTAssertTrue(fixture.model.thumbnails.isEmpty)
        XCTAssertTrue(fixture.model.thumbnailStates.isEmpty)
    }

    func testPeriodicRefreshDoesNotStackWhileInitialCaptureIsPending() async throws {
        let fixture = CaptureModelFixture(blocked: true)
        defer { fixture.close() }
        fixture.model.arm(reverse: false)
        try await waitForCalls(1, fixture.capture)
        try await Task.sleep(for: .milliseconds(2200))
        let calls = await fixture.capture.calls.count
        XCTAssertEqual(calls, 1)
        await fixture.capture.finish(batch: 1)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("State transition did not complete")
    }

    private func waitForCalls(_ count: Int, _ capture: ModelCaptureProbe) async throws {
        for _ in 0..<100 {
            if await capture.calls.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Capture did not start")
    }
}

@MainActor
private final class CaptureModelFixture {
    let capture: ModelCaptureProbe
    let model: SwitcherModel
    let defaults: UserDefaults
    let suite = "ThumbnailStateTests.\(UUID().uuidString)"

    init(granted: Bool = true, blocked: Bool = false, returnImages: Bool = false, windowCount: Int = 2,
         displayMode: Preferences.DisplayMode = .windows, frontmostPID: pid_t? = nil,
         focus: @escaping (WindowInfo) -> Void = { _ in }) {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(displayMode.rawValue, forKey: Preferences.Key.displayMode)
        defaults.set(0, forKey: Preferences.Key.switcherShowDelayMs)
        let probe = ModelCaptureProbe(blocked: blocked, returnImages: returnImages)
        capture = probe
        let windows = (1...windowCount).map { WindowInfo(id: CGWindowID($0), pid: 101, title: "Example \($0)", bounds: CGRect(x: 0, y: 0, width: 800, height: 600), isOnScreen: true) }
        let app = AppEntry(pid: 101, bundleIdentifier: "test.example", name: "Example", icon: nil, windows: windows)
        model = SwitcherModel(focusTracker: FocusTracker(), defaults: defaults, dependencies: .init(
            enumerate: { _, _ in [app] }, focusApp: { _ in }, focusWindow: focus,
            closeWindow: { _ in false }, minimizeWindow: { _ in false }, zoomWindow: { _ in false },
            hideApp: { _ in false }, focusPID: { _ in }, frontmostPID: { frontmostPID },
            frontmostBundleID: { nil }, focusedWindowID: { _ in nil },
            thumbnails: { ids, fresh, progress in await probe.load(ids, fresh: fresh, progress: progress) },
            screenCaptureGranted: { granted },
            setThumbnailCaptureAllowed: { allowed in await probe.permission(allowed) }
        ))
    }

    func close() { model.cancel(); defaults.removePersistentDomain(forName: suite) }
}

private actor ModelCaptureProbe {
    let blocked: Bool
    let returnImages: Bool
    private(set) var calls: [[CGWindowID]] = []
    private(set) var freshRequests: [Bool] = []
    private(set) var permissions: [Bool] = []
    private var progressHandlers: [Int: ThumbnailProgressHandler] = [:]
    private var waiters: [Int: CheckedContinuation<[CGWindowID: NSImage], Never>] = [:]
    init(blocked: Bool, returnImages: Bool = false) { self.blocked = blocked; self.returnImages = returnImages }

    func load(_ ids: [CGWindowID], fresh: Bool, progress: ThumbnailProgressHandler?) async -> [CGWindowID: NSImage] {
        calls.append(ids)
        freshRequests.append(fresh)
        let batch = calls.count
        progressHandlers[batch] = progress
        if blocked { return await withCheckedContinuation { waiters[batch] = $0 } }
        if returnImages {
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, NSImage(size: NSSize(width: 100 + batch, height: 24))) })
        }
        return [:]
    }

    func permission(_ allowed: Bool) { permissions.append(allowed) }
    func progress(batch: Int, id: CGWindowID) async {
        await progressHandlers[batch]?(id, NSImage(size: NSSize(width: 100 + batch, height: 24)))
    }
    func finish(batch: Int, imageID: CGWindowID? = nil) {
        let result = imageID.map { [$0: NSImage(size: NSSize(width: 100 + batch, height: 24))] } ?? [:]
        waiters.removeValue(forKey: batch)?.resume(returning: result)
    }
}
