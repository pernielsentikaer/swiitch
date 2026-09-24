import ApplicationServices
@testable import Swiitch
import XCTest

final class PermissionsMonitorTests: XCTestCase {
    @MainActor
    func testPollingRateFollowsVisiblePermissionUI() {
        let monitor = PermissionsMonitor(backgroundInterval: 2, foregroundInterval: 0.5)
        XCTAssertNil(monitor.currentInterval, "Nothing polls until the app asks")

        monitor.start()
        XCTAssertEqual(monitor.currentInterval, 2)

        monitor.beginForegroundPolling()
        monitor.beginForegroundPolling()
        XCTAssertEqual(monitor.currentInterval, 0.5, "Any visible permission UI raises the rate")
        monitor.endForegroundPolling()
        XCTAssertEqual(monitor.currentInterval, 0.5, "The rate stays raised while one UI is still visible")
        monitor.endForegroundPolling()
        XCTAssertEqual(monitor.currentInterval, 2)
        monitor.endForegroundPolling()
        XCTAssertEqual(monitor.currentInterval, 2, "Unbalanced end calls never go negative")

        monitor.stop()
        XCTAssertNil(monitor.currentInterval)
        monitor.beginForegroundPolling()
        XCTAssertEqual(monitor.currentInterval, 0.5, "Foreground polling works without app-lifetime polling")
        monitor.endForegroundPolling()
        XCTAssertNil(monitor.currentInterval)
    }

    @MainActor
    func testRefreshReflectsCurrentProcessState() {
        let monitor = PermissionsMonitor()
        monitor.refresh()
        XCTAssertEqual(monitor.accessibilityGranted, AXIsProcessTrusted())
        XCTAssertEqual(monitor.screenCaptureGranted, CGPreflightScreenCaptureAccess())
    }
}
