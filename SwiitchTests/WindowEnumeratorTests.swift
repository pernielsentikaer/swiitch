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

    func testChatGPTComputerUseHelpersAreExcluded() {
        for title in ["Computer Use", "Computer Use Controls"] {
            XCTAssertTrue(
                WindowEnumerator.isKnownAuxiliaryWindow(
                    bundleID: "com.openai.codex",
                    title: title,
                    bounds: CGRect(x: 2567, y: 604, width: 332, height: 286)
                )
            )
        }
    }

    func testNormalChatGPTWindowIsKept() {
        XCTAssertFalse(
            WindowEnumerator.isKnownAuxiliaryWindow(
                bundleID: "com.openai.codex",
                title: "ChatGPT",
                bounds: CGRect(x: 150, y: 111, width: 2707, height: 1463)
            )
        )
    }

    func testLargeChatGPTWindowWithComputerUseTitleIsKept() {
        XCTAssertFalse(
            WindowEnumerator.isKnownAuxiliaryWindow(
                bundleID: "com.openai.codex",
                title: "Computer Use",
                bounds: CGRect(x: 150, y: 111, width: 1200, height: 800)
            )
        )
    }

    func testChatGPTHelperTitleFromAnotherAppIsKept() {
        XCTAssertFalse(
            WindowEnumerator.isKnownAuxiliaryWindow(
                bundleID: "com.example.App",
                title: "Computer Use Controls",
                bounds: CGRect(x: 2567, y: 604, width: 332, height: 286)
            )
        )
    }
}
