import AppKit
import SwiftUI
@testable import Swiitch
import XCTest

@MainActor
final class LocalizationTests: XCTestCase {
    private var appBundle: Bundle { Bundle(for: AppDelegate.self) }

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(appBundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testDanishResourcesAndEnglishFallbackArePackaged() throws {
        let danish = try languageBundle("da")
        let english = try languageBundle("en")
        XCTAssertEqual(appBundle.developmentLocalization, "en")
        XCTAssertEqual(danish.localizedString(forKey: "General", value: nil, table: nil), "Generelt")
        XCTAssertEqual(danish.localizedString(forKey: "Current app's windows", value: nil, table: nil), "Den aktive apps vinduer")
        XCTAssertEqual(english.localizedString(forKey: "General", value: nil, table: nil), "General")
        XCTAssertEqual(english.localizedString(forKey: "Include minimized windows", value: nil, table: nil), "Include minimized windows")
        for language in [danish, english] {
            let permission = language.localizedString(forKey: "NSScreenCaptureUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertNotEqual(permission, "NSScreenCaptureUsageDescription")
            XCTAssertTrue(permission.contains("Swiitch"))
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: ["en", "da"], forPreferences: ["fr", "en"]), ["en"])
    }

    func testEveryPackagedDanishStringPreservesItsFormatArguments() throws {
        let bundle = try languageBundle("da")
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let table = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        XCTAssertGreaterThanOrEqual(table.count, 204)
        let token = try NSRegularExpression(pattern: "%(@|lld|d|f|%)")
        func arguments(_ string: String) -> [String] {
            token.matches(in: string, range: NSRange(string.startIndex..., in: string)).map {
                (string as NSString).substring(with: $0.range)
            }
        }
        for (key, value) in table {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            XCTAssertEqual(arguments(key), arguments(value), key)
        }
        XCTAssertEqual(String(format: bundle.localizedString(forKey: "%lld windows", value: nil, table: nil), 12), "12 vinduer")
        XCTAssertEqual(bundle.localizedString(forKey: "Swiitch", value: nil, table: nil), "Swiitch")
    }

    func testDerivedLabelsFollowTheProcessLanguageWithoutTranslatingWindowTitles() {
        let danish = appBundle.preferredLocalizations.first == "da"
        XCTAssertEqual(PreferencesSection.general.title, danish ? "Generelt" : "General")
        XCTAssertEqual(Preferences.DisplayMode.windows.label, danish ? "Alle vinduer" : "All windows")
        XCTAssertEqual(WindowAction.close.title, danish ? "Luk vindue" : "Close window")
        XCTAssertEqual(WindowActionResult.failed.message(for: .close), danish
            ? "Kunne ikke lukke dette vindue. Prøv igen."
            : "Couldn’t close this window. Please try again.")
        XCTAssertEqual(WindowInfo(id: 1, pid: 1, title: "", bounds: .zero, isOnScreen: true).displayTitle,
                       danish ? "Uden titel" : "Untitled")
        XCTAssertEqual(WindowInfo(id: 1, pid: 1, title: "My actual document", bounds: .zero, isOnScreen: true).displayTitle,
                       "My actual document")
    }

    func testRenderPreferencesInCurrentAppLanguage() throws {
        let suite = "com.swiitch.localization-render.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        Preferences.registerDefaults(in: defaults, persistentDomainName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        for section in PreferencesSection.allCases {
            for dark in [false, true] {
                let view = PreferencesView(initialSelection: section)
                    .defaultAppStorage(defaults)
                    .preferredColorScheme(dark ? .dark : .light)
                    .frame(width: 780, height: 650)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 780, height: 650)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = NSImage(size: host.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Preferences-\(appBundle.preferredLocalizations.first ?? "unknown")-\(section.rawValue)-\(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
