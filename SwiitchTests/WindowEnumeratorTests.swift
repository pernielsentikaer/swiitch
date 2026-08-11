import CoreGraphics
@testable import Swiitch
import XCTest

final class WindowEnumeratorTests: XCTestCase {
    func testWarpDedicatedHotkeyHelperIsExcluded() {
        XCTAssertTrue(
            WindowEnumerator.isKnownAuxiliaryWindow(
                bundleID: "dev.warp.Warp-Stable",
                title: "",
                bounds: CGRect(x: 0, y: 1192, width: 500, height: 500)
            )
        )
    }

    func testTitledWarpTerminalIsKept() {
        XCTAssertFalse(
            WindowEnumerator.isKnownAuxiliaryWindow(
                bundleID: "dev.warp.Warp-Stable",
                title: "~/projects/swiitch",
                bounds: CGRect(x: 100, y: 100, width: 1200, height: 800)
            )
        )
    }

    func testLargeUntitledWarpWindowIsKept() {
        XCTAssertFalse(
            WindowEnumerator.isKnownAuxiliaryWindow(
                bundleID: "dev.warp.Warp-Stable",
                title: "",
                bounds: CGRect(x: 100, y: 100, width: 1200, height: 800)
            )
        )
    }

    func testSameHelperGeometryFromAnotherAppIsKept() {
        XCTAssertFalse(
            WindowEnumerator.isKnownAuxiliaryWindow(
                bundleID: "com.example.Terminal",
                title: "",
                bounds: CGRect(x: 0, y: 1192, width: 500, height: 500)
            )
        )
    }
}
