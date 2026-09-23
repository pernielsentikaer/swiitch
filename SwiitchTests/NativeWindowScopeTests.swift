import AppKit
import ApplicationServices
@testable import Swiitch
import XCTest

/// Opt-in native integration: only creates and operates on its own empty test windows.
/// Does not request permission, touch user documents, or change system/app preferences.
@MainActor
final class NativeWindowScopeTests: XCTestCase {
    func testNativeThumbnailCaptureIsPixelBoundedAndCached() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIITCH_NATIVE_WINDOW_TESTS"] == "1",
                          "Run the opt-in native window integration check on an interactive Mac.")
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(),
                          "Existing Screen Recording permission is required; never request it in tests.")
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 40,
                                                 y: screen.visibleFrame.minY + 60,
                                                 width: 1_440, height: 880),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Swiitch disposable capture test"
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let id = CGWindowID(window.windowNumber)
        let cache = WindowThumbnails(permissionCheck: { CGPreflightScreenCaptureAccess() })
        let first = await cache.images(for: [id])
        let image = try XCTUnwrap(first[id], "The native path must capture the disposable test window")
        let representation = try XCTUnwrap(image.representations.first)
        XCTAssertLessThanOrEqual(representation.pixelsWide, 720)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 720)
        let second = await cache.images(for: [id], maximumAge: .infinity)
        XCTAssertTrue(image === second[id], "Warm cache reads must return the same captured image")
        let stats = await cache.statistics
        XCTAssertEqual(stats.cachedImages, 1)
        XCTAssertLessThanOrEqual(stats.cacheBytes, 720 * 720 * 4)
        print("Native thumbnail: \(representation.pixelsWide)x\(representation.pixelsHigh), cachedBytes=\(stats.cacheBytes)")
    }

    func testNativeMinimizeDiscoveryFilteringAndRestore() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIITCH_NATIVE_WINDOW_TESTS"] == "1",
                          "Run the opt-in native window integration check on an interactive Mac.")
        try XCTSkipUnless(AXIsProcessTrusted(), "Existing Accessibility permission is required; never request it in tests.")
        let screen = try XCTUnwrap(NSScreen.main)
        let origin = screen.visibleFrame.origin
        func makeWindow(_ title: String, offset: CGFloat) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: origin.x + 40 + offset, y: origin.y + 60 + offset,
                                                       width: 480, height: 320),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = title
            window.orderFront(nil)
            return window
        }
        let first = makeWindow("Swiitch test document A", offset: 0)
        let second = makeWindow("Swiitch test document B", offset: 30)
        defer { first.close(); second.close() }
        let pid = ProcessInfo.processInfo.processIdentifier
        let firstID = CGWindowID(first.windowNumber)
        let secondID = CGWindowID(second.windowNumber)
        let context = WindowEnumerator.Context(applications: [
            .init(processIdentifier: pid, bundleIdentifier: Bundle.main.bundleIdentifier,
                  localizedName: "Swiitch test host", icon: nil),
        ], options: .init(), screenFrame: nil)
        func collect() async -> [WindowInfo] {
            await Task.detached { WindowEnumerator.collect(context: context).apps.flatMap(\.windows) }.value
        }
        try await Task.sleep(for: .milliseconds(150))
        let initial = await collect()
        let target = try XCTUnwrap(initial.first { $0.id == secondID })
        XCTAssertTrue(initial.contains { $0.id == firstID && $0.isOnScreen })
        XCTAssertEqual(WindowFocuser.perform(.minimize, window: target), .accepted)
        for _ in 0..<20 where !second.isMiniaturized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(second.isMiniaturized)
        let minimized = await collect()
        let minimizedTarget = try XCTUnwrap(minimized.first { $0.id == secondID })
        XCTAssertEqual(minimizedTarget.isMinimized, true)
        XCTAssertFalse(minimizedTarget.isOnScreen)
        XCTAssertTrue(EnumerateOptions(includeOtherSpaces: false, includeMinimizedWindows: true).includes(minimizedTarget))
        XCTAssertFalse(EnumerateOptions(includeOtherSpaces: true, includeMinimizedWindows: false).includes(minimizedTarget))
        XCTAssertTrue(WindowFocuser.isWindowPresent(minimizedTarget), "Exact identity must also resolve while minimized")
        let axTarget = AXPrivate.windows(forPID: pid).first { AXPrivate.windowID(for: $0) == secondID }
        XCTAssertNotNil(axTarget, "Minimized window must remain in the app's AX list")
        if let axTarget {
            var value: AnyObject?
            let read = AXUIElementCopyAttributeValue(axTarget, kAXMinimizedAttribute as CFString, &value)
            print("Native minimized target: present=\(WindowFocuser.isWindowPresent(minimizedTarget)), read=\(read.rawValue), bool=\(String(describing: value as? Bool)), active=\(NSRunningApplication.current.isActive)")
        }
        WindowFocuser.focus(window: minimizedTarget)
        for _ in 0..<20 where second.isMiniaturized {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(second.isMiniaturized, "Selecting the minimized tile must restore the same native window")
        let restored = await collect()
        XCTAssertEqual(restored.first { $0.id == secondID }?.isMinimized, false)
        XCTAssertTrue(restored.contains { $0.id == firstID }, "The sibling document must survive unchanged")
    }
}
