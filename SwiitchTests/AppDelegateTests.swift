import AppKit
@testable import Swiitch
import XCTest

final class AppDelegateTests: XCTestCase {
    func testPreferencesWindowTemporarilyUsesRegularActivationPolicy() {
        XCTAssertEqual(
            AppDelegate.activationPolicy(showDockIcon: false, preferencesOpen: true),
            .regular
        )
    }

    func testClosedPreferencesRestoresDockIconPreference() {
        XCTAssertEqual(
            AppDelegate.activationPolicy(showDockIcon: false, preferencesOpen: false),
            .accessory
        )
        XCTAssertEqual(
            AppDelegate.activationPolicy(showDockIcon: true, preferencesOpen: false),
            .regular
        )
    }

    func testFirstLaunchShowsWelcome() {
        XCTAssertEqual(
            AppDelegate.startupPresentation(
                hasCompletedOnboarding: false,
                accessibilityGranted: false
            ),
            .welcome
        )
    }

    func testCompletedOnboardingUsesPreferencesForPermissionRecovery() {
        XCTAssertEqual(
            AppDelegate.startupPresentation(
                hasCompletedOnboarding: true,
                accessibilityGranted: false
            ),
            .preferences
        )
    }

    func testCompletedAndAuthorizedLaunchStaysQuiet() {
        XCTAssertEqual(
            AppDelegate.startupPresentation(
                hasCompletedOnboarding: true,
                accessibilityGranted: true
            ),
            .none
        )
    }
}
