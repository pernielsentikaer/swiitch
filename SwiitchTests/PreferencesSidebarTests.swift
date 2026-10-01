import AppKit
import SwiftUI
import XCTest
@testable import Swiitch

@MainActor
final class PreferencesSidebarTests: XCTestCase {
    func testSidebarCannotCollapseAndClampsDividerAtMinimumWidth() throws {
        let suite = "com.swiitch.sidebar-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        Preferences.registerDefaults(in: defaults, persistentDomainName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingController(rootView: PreferencesView(initialSelection: .about)
            .defaultAppStorage(defaults))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setContentSize(NSSize(width: 780, height: 600))

        var splitView: NSSplitView?
        XCTAssertTrue(waitUntil {
            host.view.layoutSubtreeIfNeeded()
            splitView = self.findSplitView(host.view)
            return splitView?.arrangedSubviews.count == 2
        })
        let split = try XCTUnwrap(splitView)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
        var tableView: NSTableView?
        XCTAssertTrue(waitUntil {
            host.view.layoutSubtreeIfNeeded()
            tableView = self.findTableView(sidebar)
            return tableView?.numberOfRows == PreferencesSection.allCases.count
        }, "All preferences sections must remain available in the sidebar")
        let delegate = try XCTUnwrap(split.delegate)
        XCTAssertFalse(delegate.splitView?(split, canCollapseSubview: sidebar) ?? false,
                       "Reject collapse before it happens, rather than reopening afterwards")

        for width in [CGFloat(720), 780, 1100] {
            window.setContentSize(NSSize(width: width, height: 600))
            host.view.layoutSubtreeIfNeeded()
            // SwiftUI supplies Auto Layout limits, not necessarily the optional
            // constrainMinCoordinate delegate callback. Exercise the actual divider.
            for position in [CGFloat(-1000), 0, 1, 40, 169, 170, 190, 220, 10000] {
                split.setPosition(position, ofDividerAt: 0)
                // Check immediately as well as after layout: a collapse followed by
                // an asynchronous reopen passes an eventual-visibility assertion.
                assertSidebarBounds(split, sidebar, windowWidth: width, position: position)
                host.view.layoutSubtreeIfNeeded()
                assertSidebarBounds(split, sidebar, windowWidth: width, position: position)
            }
        }

        window.setContentSize(NSSize(width: 780, height: 600))
        split.setPosition(190, ofDividerAt: 0)
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let image = NSImage(size: host.view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Preferences-noncollapsible-sidebar"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertSidebarBounds(_ split: NSSplitView, _ sidebar: NSView,
                                     windowWidth: CGFloat, position: CGFloat,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let context = "Window \(windowWidth), requested divider \(position)"
        XCTAssertFalse(split.isSubviewCollapsed(sidebar), context, file: file, line: line)
        XCTAssertGreaterThanOrEqual(sidebar.frame.width, 170, context, file: file, line: line)
        XCTAssertLessThanOrEqual(sidebar.frame.width, 220, context, file: file, line: line)
    }

    private func findSplitView(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let split = findSplitView(child) { return split }
        }
        return nil
    }

    private func findTableView(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = findTableView(child) { return table }
        }
        return nil
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if predicate() { return true }
        } while Date() < deadline
        return false
    }
}
