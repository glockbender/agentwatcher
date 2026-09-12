import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// What a fresh install finds in its settings file.
///
/// The requirement is that the file describes the widget completely rather than by absence:
/// a person opening it reads what the app is going to do, instead of reading a few keys and
/// having to know what the source does about the rest.
@MainActor
final class PreferenceSeedingTests: XCTestCase {
    func testAFirstLaunchWritesEverySettingOut() throws {
        let (preferences, owners) = try makeStores()

        seed(owners, into: preferences)

        for owner in owners {
            for key in owner.defaultValues.keys {
                XCTAssertTrue(
                    preferences.string(forKey: key) != nil
                        || preferences.number(forKey: key) != nil
                        || preferences.flag(forKey: key) != nil,
                    "\(key) was not written"
                )
            }
        }
    }

    func testAutomaticUpdatePreferenceIsSeededOnFirstLaunch() throws {
        let (preferences, owners) = try makeStores()
        seed(owners, into: preferences)
        XCTAssertEqual(preferences.flag(forKey: "checkForUpdatesOnLaunch"), true)
    }

    /// The size is seeded like everything else, and what used to be its absence is now a
    /// value beside it: `widgetSizeFollowsSessions`. A widget that has never been resized
    /// still has a size to open at and still follows the session count.
    func testTheWidgetsSizeIsSeededAlongWithTheReasonItKeepsMoving() throws {
        let (preferences, owners) = try makeStores()

        seed(owners, into: preferences)

        XCTAssertEqual(preferences.number(forKey: "widgetWidth"), Double(HUDFrameStore.defaultSize.width))
        XCTAssertEqual(preferences.number(forKey: "widgetHeight"), Double(HUDFrameStore.defaultSize.height))
        XCTAssertEqual(preferences.flag(forKey: "widgetSizeFollowsSessions"), true)
    }

    /// The one key still written by nothing at launch, because there is no answer to write:
    /// where the widget goes depends on the screen. The controller writes it the moment the
    /// widget is first actually placed.
    func testThePositionIsWrittenAtTheFirstPlacementRatherThanSeeded() throws {
        let (preferences, owners) = try makeStores()

        seed(owners, into: preferences)

        XCTAssertNil(preferences.number(forKey: "widgetOriginX"))
        XCTAssertNil(preferences.number(forKey: "widgetOriginY"))
    }

    func testASettingChosenBeforeAnUpdateSurvivesTheNextLaunchsSeeding() throws {
        let (preferences, owners) = try makeStores()
        let lampSchemes = LampSchemeStore(preferences: preferences)
        lampSchemes.setColor(NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), for: .executing)
        WidgetBackgroundStore(preferences: preferences).select(.mint)

        seed(owners, into: preferences)

        XCTAssertEqual(lampSchemes.scheme.style(for: .executing).color.srgbHex, "#FF00FF")
        XCTAssertEqual(WidgetBackgroundStore(preferences: preferences).selected, .mint)
        XCTAssertEqual(
            lampSchemes.scheme.style(for: .failed).color.srgbHex,
            SessionPhase.failed.defaultLampStyle.color.srgbHex,
            "and the phases it never mentioned are written out as the defaults"
        )
    }

    /// A widget resized by hand before `widgetSizeFollowsSessions` existed keeps that size
    /// on the launch that adds the key.
    ///
    /// The rule used to be the shape of the file rather than a value in it: a size meant the
    /// widget had been resized and the chosen size won for good. Seeding a plain `true` would
    /// hand every such widget back to the session count while the file still named the size,
    /// so it would look preserved and be permanently ignored.
    func testAWidgetResizedBeforeTheKeyExistedIsNotHandedBackToTheSessionCount() throws {
        let preferences = try isolatedPreferences()
        // The file exactly as the previous version left it: a size, and nothing about
        // following the session count.
        preferences.set(380.0, forKey: "widgetWidth")
        preferences.set(300.0, forKey: "widgetHeight")
        let frameStore = HUDFrameStore(preferences: preferences)

        XCTAssertFalse(
            frameStore.sizeFollowsSessions,
            "a size with no key beside it is the old way of saying the widget was resized"
        )

        seed([frameStore], into: preferences)

        XCTAssertEqual(preferences.flag(forKey: "widgetSizeFollowsSessions"), false)
        XCTAssertEqual(frameStore.size, NSSize(width: 380, height: 300))
    }

    /// The other half of the same rule: a file from before the key that never carried a size
    /// is a widget that was never resized, and it goes on sizing itself.
    func testAWidgetNeverResizedBeforeTheKeyExistedGoesOnFollowing() throws {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)

        XCTAssertTrue(frameStore.sizeFollowsSessions)

        seed([frameStore], into: preferences)

        XCTAssertEqual(preferences.flag(forKey: "widgetSizeFollowsSessions"), true)
    }

    private func makeStores() throws -> (PreferenceFile, [PreferenceDefaults]) {
        let preferences = try isolatedPreferences()
        return (
            preferences,
            [
                WidgetBackgroundStore(preferences: preferences),
                WidgetSettingsStore(preferences: preferences),
                HUDFrameStore(preferences: preferences),
                LampSchemeStore(preferences: preferences),
                AppUpdater(preferences: preferences),
            ]
        )
    }

    /// The same merge `AppDelegate` does at launch.
    private func seed(_ owners: [PreferenceDefaults], into preferences: PreferenceFile) {
        var everyDefault: [String: JSONValue] = [:]
        for owner in owners {
            everyDefault.merge(owner.defaultValues) { existing, _ in existing }
        }
        preferences.seed(everyDefault)
    }
}
