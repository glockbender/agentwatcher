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
            shortcutStatusLine(.taken(shortcut)),
            shortcutStatusLine(.refused(shortcut, code: -50)),
        ]

        for line in lines {
            XCTAssertFalse(line.isEmpty)
        }
        XCTAssertEqual(Set(lines).count, lines.count, "two states that read alike are one state")
    }

    /// Which combination failed is the whole point: a person with two shortcuts set in other
    /// applications cannot act on "the shortcut is taken".
    func testAFailureNamesTheCombinationItIsAbout() throws {
        let shortcut = try XCTUnwrap(WidgetShortcut(keyCode: 13, modifiers: [.option, .command]))

        XCTAssertTrue(shortcutStatusLine(.taken(shortcut)).contains("⌥⌘W"))
        XCTAssertTrue(shortcutStatusLine(.refused(shortcut, code: -50)).contains("⌥⌘W"))
    }

    func testWithNoShortcutSetTheLineClaimsNoCombination() {
        XCTAssertFalse(shortcutStatusLine(.none).contains("⌘"))
    }
}
