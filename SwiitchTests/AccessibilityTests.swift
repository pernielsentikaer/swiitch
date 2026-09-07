import AppKit
import SwiftUI
@testable import Swiitch
import XCTest

@MainActor
final class AccessibilityTests: XCTestCase {
    func testWindowCellExposesIdentitySelectedStateAndActionsWithoutHover() throws {
        var commits = 0
        let full = WindowCell(title: "Example document", thumbnail: nil, thumbnailState: .unavailable,
            appIcon: nil, accessibilityAppName: "Example app", overlayPosition: .hidden,
            isSelected: true, thumbHeight: 150, showControlsOnHover: false,
            controls: .init(close: {}, minimize: {}, zoom: {}), commit: { commits += 1 })
            .frame(width: 260, height: 190)
        let limited = WindowCell(title: "Limited document", thumbnail: nil, thumbnailState: .unavailable,
            appIcon: nil, accessibilityAppName: "Example app", overlayPosition: .hidden,
            isMinimized: true, isSelected: false, thumbHeight: 150, showControlsOnHover: false,
            controls: .init(close: {}, minimize: {}, zoom: {},
                            capabilities: .init(close: .unsupported, minimize: .disabled, zoom: .available)), commit: {})
            .frame(width: 260, height: 190)
        let cell = HStack { full; limited }.frame(width: 540, height: 190)
        let host = NSHostingView(rootView: cell)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 190),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        // SwiftUI lazily creates accessibility nodes for visible, ordered content.
        // This is a synthetic window; never make it key or operate on real documents.
        window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Optional bounded inspection window for an external AX client. Xcode forwards
        // TEST_RUNNER_SWIITCH_AX_INSPECTION_SECONDS to this test-only environment key.
        let inspection = Double(ProcessInfo.processInfo.environment["SWIITCH_AX_INSPECTION_SECONDS"] ?? "0") ?? 0
        RunLoop.main.run(until: Date().addingTimeInterval(max(0.1, min(inspection, 30))))
        let elements = descendants(window)
        let tree = elements.map { "\(type(of: $0)): role=\($0.accessibilityRole?()?.rawValue ?? "nil"), label=\($0.accessibilityLabel?() ?? "nil")" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: tree)
        attachment.name = "Window-cell-accessibility-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Some macOS/Xcode hosts never activate SwiftUI's AX bridge without an
        // external accessibility client. Do not mistake a missing test bridge for
        // either a passing assertion or a product regression. Keep live AX inspection
        // in the release checklist; assert everything below whenever nodes exist.
        try XCTSkipIf(children(host).isEmpty,
            "The hosted SwiftUI accessibility tree is unavailable; requires live AX/UI testing.")
        let target = try XCTUnwrap(elements.first { $0.accessibilityLabel?() == "Example document, Example app" })
        XCTAssertEqual(target.accessibilityRole?(), .button)
        XCTAssertEqual(target.isAccessibilitySelected?(), true)
        // AnyObject lookup is ambiguous across the switch/radio/stepper overloads.
        let value = (target as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
        XCTAssertEqual(value as? String, ThumbnailState.unavailable.label)
        let names = target.accessibilityCustomActions?()?.map(\.name) ?? []
        XCTAssertTrue(names.contains(WindowAction.close.title), names.description)
        XCTAssertTrue(names.contains(WindowAction.minimize.title), names.description)
        XCTAssertTrue(names.contains(WindowAction.zoom.title), names.description)
        XCTAssertEqual(target.accessibilityPerformPress?(), true)
        XCTAssertEqual(commits, 1)
        let limitedTarget = try XCTUnwrap(elements.first { $0.accessibilityLabel?() == "Limited document, Example app" })
        let limitedNames = limitedTarget.accessibilityCustomActions?()?.map(\.name) ?? []
        XCTAssertEqual(limitedNames, [WindowAction.zoom.title], "Unavailable actions must not be offered to VoiceOver")
        let minimizedValue = (limitedTarget as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
        XCTAssertEqual(minimizedValue as? String, "\(String(localized: "Minimized")), \(ThumbnailState.unavailable.label)")
        XCTAssertEqual(limitedTarget.accessibilityPerformPress?(), true, "Minimized is not disabled")
    }

    // SwiftUI's AccessibilityNode exposes the public ObjC AX selectors without
    // declaring NSAccessibilityProtocol conformance. Query those selectors dynamically.
    private func children(_ node: AnyObject) -> [Any] {
        node.accessibilityChildren?() ?? []
    }

    private func descendants(_ item: Any, depth: Int = 0) -> [AnyObject] {
        guard depth < 12 else { return [] }
        let node = item as AnyObject
        return [node] + children(node).flatMap { descendants($0, depth: depth + 1) }
    }
}
