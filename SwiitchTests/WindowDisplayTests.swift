import AppKit
@testable import Swiitch
import XCTest

final class WindowDisplayTests: XCTestCase {
    private let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                           CGRect(x: 1440, y: -200, width: 1920, height: 1080)]

    func testDisplayFollowsFocusedFrameForTwoWindowsOfOneApp() {
        let first = CGRect(x: 100, y: 100, width: 800, height: 600)
        let second = CGRect(x: 1600, y: 0, width: 900, height: 700)
        XCTAssertEqual(WindowEnumerator.screenIndex(forFocusedFrame: second, screens: screens), 1)
        XCTAssertEqual(WindowEnumerator.screenIndex(forFocusedFrame: first, screens: screens), 0)
    }

    func testStraddlingWindowUsesLargestOverlapNotTopLeftCorner() {
        XCTAssertEqual(WindowEnumerator.screenIndex(
            forFocusedFrame: CGRect(x: 1300, y: 100, width: 1000, height: 700), screens: screens
        ), 1)
    }

    func testInvalidAndOffDesktopFramesFallBackSafely() {
        for frame in [CGRect.zero, .null, .infinite, CGRect(x: -10000, y: 0, width: 100, height: 100)] {
            XCTAssertNil(WindowEnumerator.screenIndex(forFocusedFrame: frame, screens: screens))
        }
        XCTAssertNil(WindowEnumerator.screenIndex(forFocusedFrame: screens[0], screens: []))
    }
}
