import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The template as it is kept between launches.
///
/// Flat keys, the way `LampSchemeStore` writes nine phases: `PreferenceFile` takes a string, a
/// number or a flag and nothing else, and the order reads as a line a person can correct by
/// hand. The tests here are about what a hand-corrected — or older, or newer — file does.
final class RowLayoutStoreTests: XCTestCase {
    func testAFileThatSaysNothingGivesTheRowTheAppAlwaysDrew() throws {
        let store = RowLayoutStore(preferences: try isolatedPreferences())

        XCTAssertEqual(store.layout, .standard)
    }

    func testAnOrderWrittenToTheFileIsTheOrderRead() throws {
        let preferences = try isolatedPreferences()
        preferences.set("lamp,name,gap,timer", forKey: "rowLayout.parts")
        let store = RowLayoutStore(preferences: preferences)

        XCTAssertEqual(store.layout.parts, [.lamp, .name, .gap, .timer])
    }

    /// A file written by a later version names parts this one has never heard of. Dropping
    /// them quietly is the same fail-open rule monitoring follows: a row missing one part is
    /// worth more than no row at all, and refusing the file would leave the widget empty.
    func testAPartThisVersionDoesNotKnowIsDropped() throws {
        let preferences = try isolatedPreferences()
        preferences.set("timer,usageLimits,name,gap", forKey: "rowLayout.parts")
        let store = RowLayoutStore(preferences: preferences)

        XCTAssertEqual(store.layout.parts, [.timer, .name, .gap])
    }

    func testATemplateWrittenByTheWindowIsTheOneReadBack() throws {
        let preferences = try isolatedPreferences()
        let store = RowLayoutStore(preferences: preferences)
        let chosen = RowLayout(
            parts: [.lamp, .name, .gap, .branch],
            flexible: .branch,
            counterKinds: [.shell],
            nameStyle: .title,
            contextStyle: .both,
            reservesDismissColumn: true
        )

        store.setLayout(chosen)

        XCTAssertEqual(RowLayoutStore(preferences: preferences).layout, chosen)
    }

    // MARK: - What a launch writes

    /// The file says what the widget is going to do rather than leaving it to the source, so
    /// the launch that finds no template writes the app's own out in full.
    func testALaunchWithNoTemplateWritesTheAppsOwnOut() throws {
        let preferences = try isolatedPreferences()
        let store = RowLayoutStore(preferences: preferences)

        preferences.seed(store.defaultValues)

        XCTAssertEqual(store.layout, .standard)
        XCTAssertEqual(
            preferences.string(forKey: "rowLayout.parts"),
            "timer,lamp,agent,fault,name,gap,counters,context"
        )
    }

    /// And a row somebody has arranged survives every launch after it: seeding fills in the
    /// keys a file lacks and touches nothing it already holds.
    func testATemplateInTheFileSurvivesTheNextLaunchsSeeding() throws {
        let preferences = try isolatedPreferences()
        preferences.set("lamp,name,gap", forKey: "rowLayout.parts")
        let store = RowLayoutStore(preferences: preferences)

        preferences.seed(store.defaultValues)

        XCTAssertEqual(store.layout.parts, [.lamp, .name, .gap])
    }
}
