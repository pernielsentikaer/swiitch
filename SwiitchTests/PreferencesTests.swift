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
        XCTAssertEqual(Preferences.DisplayMode.apps.label, "Apps first")
        XCTAssertEqual(
            Preferences.DisplayMode.apps.description,
            "Use Tab or ← → to switch apps. Press ↓ to choose a window."
        )
        XCTAssertEqual(Preferences.DisplayMode.windows.label, "All windows")
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
