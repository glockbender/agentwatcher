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

    // MARK: - The setting this one replaces

    /// `showsSessionTopic` was a flag of its own, and the template subsumes it. It is carried
    /// over exactly once, by the seeding every launch performs: a person who had switched the
    /// topic off finds a template without the name, not a row that started showing it again.
    func testATopicSwitchedOffBecomesATemplateWithoutTheName() throws {
        let preferences = try isolatedPreferences()
        preferences.set(false, forKey: "showsSessionTopic")
        let store = RowLayoutStore(preferences: preferences)

        preferences.seed(store.defaultValues)

        XCTAssertFalse(store.layout.shows(.name))
        XCTAssertEqual(store.layout.parts, [.timer, .lamp, .agent, .fault, .gap, .counters, .context])
    }

    func testATopicLeftOnBecomesTheOrdinaryTemplate() throws {
        let preferences = try isolatedPreferences()
        preferences.set(true, forKey: "showsSessionTopic")
        let store = RowLayoutStore(preferences: preferences)

        preferences.seed(store.defaultValues)

        XCTAssertEqual(store.layout, .standard)
    }

    /// The carry-over happens once and never fights a template afterwards: seeding fills in
    /// missing keys only, so a file that already holds one keeps it whatever the old flag says.
    func testAnExistingTemplateIsNotOverruledByTheOldFlag() throws {
        let preferences = try isolatedPreferences()
        preferences.set(false, forKey: "showsSessionTopic")
        preferences.set("lamp,name,gap", forKey: "rowLayout.parts")
        let store = RowLayoutStore(preferences: preferences)

        preferences.seed(store.defaultValues)

        XCTAssertEqual(store.layout.parts, [.lamp, .name, .gap])
    }
}
