import ApplicationServices
import Foundation
@testable import Swiitch
import XCTest

final class PreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.swiitch.preferences-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDisplayModeFallbackMatchesRegisteredDefault() {
        // Readers that run before `registerDefaults` (previews, tests, injected suites)
        // must agree with the registered value; the fallback used to drift to Apps first.
        // The registration domain is process-wide, so do not assume it is empty here.
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(defaults.string(forKey: Preferences.Key.displayMode),
                       Preferences.DisplayMode.default.rawValue)
        XCTAssertEqual(Preferences.DisplayMode.default, .windows)
    }

    func testResetSettingsLeavesLoginItemIntentToTheOS() {
        // The login item is owned by SMAppService. Reset must neither store nor replay an
        // intent flag, and the retired flag is removed on launch so it can never be replayed.
        defaults.set(true, forKey: "launchAtLogin")
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["launchAtLogin"])
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"), "No registered fallback may resurrect the flag")
        Preferences.resetSettings(in: defaults)
        XCTAssertNil(defaults.object(forKey: "launchAtLogin"))
    }

    func testMinimizedPreferenceDefaultsAndResetsIndependentlyOfSpaces() {
        defaults.set(false, forKey: Preferences.Key.includeOtherSpaces)
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .showLast)
        XCTAssertFalse(defaults.bool(forKey: Preferences.Key.includeOtherSpaces))
        defaults.set(Preferences.MinimizedWindows.hide.rawValue, forKey: Preferences.Key.minimizedWindows)
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .hide)
        Preferences.resetSettings(in: defaults)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .showLast)
    }

    func testLegacyMinimizedOptOutSurvivesRegisteredDefaultsAndRepeatedLaunches() {
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        defaults.set(false, forKey: "includeMinimizedWindows")
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .hide)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["includeMinimizedWindows"])
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .hide)
        Preferences.resetSettings(in: defaults)
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .showLast)
    }

    func testLegacyMinimizedInclusionUpgradesToShowLast() {
        defaults.set(true, forKey: "includeMinimizedWindows")
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .showLast)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["includeMinimizedWindows"])
    }

    func testExplicitMinimizedBehaviorWinsOverLegacyChoice() {
        for behavior in Preferences.MinimizedWindows.allCases {
            defaults.set(behavior.rawValue, forKey: Preferences.Key.minimizedWindows)
            defaults.set(false, forKey: "includeMinimizedWindows")
            Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
            XCTAssertEqual(Preferences.minimizedWindows(in: defaults), behavior)
        }
    }

    func testMissingAndInvalidMinimizedBehaviorFallBackSafely() {
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .showLast)
        defaults.set("invalid", forKey: Preferences.Key.minimizedWindows)
        XCTAssertEqual(Preferences.minimizedWindows(in: defaults), .showLast)
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertEqual(defaults.string(forKey: Preferences.Key.minimizedWindows), "showLast")
    }

    func testLegacyFillLayoutMigratesToFitToScreen() {
        defaults.set(-1, forKey: "tileColumns")

        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)

        XCTAssertTrue(defaults.bool(forKey: Preferences.Key.fitWindowGridToScreen))
        XCTAssertNil(defaults.object(forKey: "tileColumns"))
    }

    func testExplicitCurrentLayoutWinsOverLegacyPreference() {
        defaults.set(false, forKey: Preferences.Key.fitWindowGridToScreen)
        defaults.set(-1, forKey: "tileColumns")

        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)

        XCTAssertFalse(defaults.bool(forKey: Preferences.Key.fitWindowGridToScreen))
        XCTAssertNil(defaults.object(forKey: "tileColumns"))
    }

    func testObsoleteWindowListPreferenceIsRemoved() {
        defaults.set(false, forKey: "showWindowPreviews")

        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)

        XCTAssertNil(defaults.object(forKey: "showWindowPreviews"))
    }

    func testDisplayModeCopyDescribesTheNavigationModel() {
        // Resolve through the app's catalog so the test passes on a Danish host too:
        // it pins the keys the labels use, and LocalizationTests cover the translations.
        func copy(_ key: String) -> String {
            Bundle(for: SwitcherModel.self).localizedString(forKey: key, value: nil, table: nil)
        }
        XCTAssertEqual(Preferences.DisplayMode.apps.label, copy("Apps first"))
        XCTAssertEqual(
            Preferences.DisplayMode.apps.description,
            copy("Use Tab or ← → to switch apps. Press ↓ to choose a window.")
        )
        XCTAssertEqual(Preferences.DisplayMode.windows.label, copy("All windows"))
        XCTAssertNotEqual(copy("Apps first"), copy("All windows"))
    }

    func testWindowControlsAreOptInAndResettable() {
        Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)
        XCTAssertFalse(defaults.bool(forKey: Preferences.Key.showWindowControlsOnHover))

        defaults.set(true, forKey: Preferences.Key.showWindowControlsOnHover)
        Preferences.resetSettings(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: Preferences.Key.showWindowControlsOnHover))
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?[Preferences.Key.showWindowControlsOnHover])
    }

    func testMinimalAndSpotlightApplySystemAdaptiveSolidMaterial() {
        for preset in [Preferences.ThemePreset.minimal, .spotlight] {
            preset.apply(defaults: defaults)
            XCTAssertEqual(
                defaults.string(forKey: Preferences.Key.panelMaterial),
                Preferences.PanelMaterial.solid.rawValue
            )
        }
    }

    func testExistingSystemAdaptivePresetsMigrateFromSolidLight() {
        for preset in [Preferences.ThemePreset.minimal, .spotlight] {
            defaults.set(preset.rawValue, forKey: Preferences.Key.themePreset)
            defaults.set(
                Preferences.PanelMaterial.solidLight.rawValue,
                forKey: Preferences.Key.panelMaterial
            )

            Preferences.registerDefaults(in: defaults, persistentDomainName: suiteName)

            XCTAssertEqual(
                defaults.string(forKey: Preferences.Key.panelMaterial),
                Preferences.PanelMaterial.solid.rawValue
            )
        }
    }

    func testPresetLabelsDoNotUseStyleSuffix() {
        XCTAssertEqual(Preferences.ThemePreset.raycast.label, "Raycast")
        XCTAssertEqual(Preferences.ThemePreset.spotlight.label, "Spotlight")
    }

    func testVirtualKeyCodeZeroRemainsAValidShortcut() {
        let shortcut = HotkeyManager.configuredShortcut(
            keyCode: 0,
            rawFlags: Int(CGEventFlags.maskCommand.rawValue)
        )

        XCTAssertEqual(shortcut?.keyCode, 0)
        XCTAssertEqual(shortcut?.flags, .maskCommand)
    }

    func testShortcutWithoutACommandModifierIsRejected() {
        XCTAssertNil(HotkeyManager.configuredShortcut(keyCode: 0, rawFlags: 0))
    }
}
