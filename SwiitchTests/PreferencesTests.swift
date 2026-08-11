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
}
