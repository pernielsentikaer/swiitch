import AppKit
import SwiftUI
@testable import Swiitch
import XCTest

@MainActor
final class ThemeTests: XCTestCase {
    func testSolidLightUsesLightForegroundSchemeInBothAppAppearances() {
        for inherited: ColorScheme in [.light, .dark] {
            XCTAssertEqual(Theme.panelColorScheme(material: .solidLight, inherited: inherited), .light)
        }
    }

    func testSolidDarkUsesDarkForegroundSchemeInBothAppAppearances() {
        for inherited: ColorScheme in [.light, .dark] {
            XCTAssertEqual(Theme.panelColorScheme(material: .solidDark, inherited: inherited), .dark)
        }
    }

    func testAdaptiveMaterialsFollowTheAppAppearance() {
        for material: Preferences.PanelMaterial in [.solid, .translucentLight, .translucent, .frosted] {
            for inherited: ColorScheme in [.light, .dark] {
                XCTAssertEqual(Theme.panelColorScheme(material: material, inherited: inherited), inherited)
            }
        }
    }

    func testPanelOverrideIsLocalAndRespondsToAppearanceChanges() {
        let appAppearance = NSApp.appearance
        for material in Preferences.PanelMaterial.allCases {
            var outer: ColorScheme?
            var inner: ColorScheme?
            func view(_ inherited: ColorScheme) -> some View {
                VStack {
                    ColorSchemeReporter { outer = $0 }
                    ColorSchemeReporter { inner = $0 }
                        .swiitchPanelAppearance(material: material)
                }
                .environment(\.colorScheme, inherited)
            }
            let host = NSHostingView(rootView: view(.light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for inherited: ColorScheme in [.light, .dark, .light] {
                host.rootView = view(inherited)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                XCTAssertEqual(outer, inherited, "The surrounding Preferences UI must keep its appearance")
                XCTAssertEqual(inner, Theme.panelColorScheme(material: material, inherited: inherited))
            }
        }
        XCTAssertTrue(NSApp.appearance === appAppearance, "No app-wide appearance mutation is allowed")
    }
}

private struct ColorSchemeReporter: View {
    @Environment(\.colorScheme) private var scheme
    let record: (ColorScheme) -> Void

    var body: some View {
        Color.clear
            .onAppear { record(scheme) }
            .onChange(of: scheme) { _, newValue in record(newValue) }
    }
}
