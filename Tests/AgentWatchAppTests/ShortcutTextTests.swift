import XCTest

@testable import AgentWatchApp

/// The sentence under the recorder is the only place the shortcut can explain itself — the menu
/// deliberately says nothing when the combination does not work.
@MainActor
final class ShortcutTextTests: XCTestCase {
    func testEveryStateSaysSomethingAndNoTwoSayTheSame() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))
        let lines = [
            shortcutStatusLine(.none),
            shortcutStatusLine(.active(shortcut)),
            shortcutStatusLine(.alreadyOurs(shortcut)),
            shortcutStatusLine(.refused(shortcut, code: -50)),
        ]

        for line in lines {
            XCTAssertFalse(line.isEmpty)
        }
        XCTAssertEqual(Set(lines).count, lines.count, "two states that read alike are one state")
    }

    /// Which combination failed is the whole point: "the shortcut did not take" tells a person
    /// with more than one combination in mind nothing they can act on.
    func testAFailureNamesTheCombinationItIsAbout() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))

        XCTAssertTrue(shortcutStatusLine(.alreadyOurs(shortcut)).contains("⌥⌘W"))
        XCTAssertTrue(shortcutStatusLine(.refused(shortcut, code: -50)).contains("⌥⌘W"))
    }

    /// Somebody reaching for `⌥⌘,` — the combination every Mac uses for settings — gets a
    /// refusal, and has no way to tell whether the modifiers or the key were the problem.
    /// Listing what is accepted does not answer that: punctuation has to be named as missing.
    func testTheRefusalSaysPunctuationIsNotOfferedAndWhy() {
        XCTAssertTrue(shortcutAcceptedKeys.lowercased().contains("punctuation"))
        XCTAssertTrue(shortcutAcceptedKeys.lowercased().contains("layout"))
    }

    func testWithNoShortcutSetTheLineClaimsNoCombination() {
        XCTAssertFalse(shortcutStatusLine(.none).contains("⌘"))
    }
}
