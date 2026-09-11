import Foundation
import XCTest

@testable import AgentWatchCore

/// Finding a session's terminal among Ghostty's, by the name the agent wrote there itself.
final class GhosttyFocusTests: XCTestCase {
    private let tabs = [
        GhosttyTerminal(id: "58E03558-BF80-475B-A933-10C473AA2812", name: "~/CommonProjects/agent-watch"),
        GhosttyTerminal(id: "EA251683-CAB4-429D-A26C-3F074120F240", name: "◐ Следующие задачи по плану"),
    ]

    /// The measured shape: Claude puts a glyph for its own state in front of the name it also
    /// reports to the widget, so the tab title ends with the session name rather than equals
    /// it.
    func testTheTabWhoseTitleEndsWithTheSessionNameIsTheOne() {
        let decision = GhosttyFocus.decision(among: tabs, sessionName: "Следующие задачи по плану")

        XCTAssertEqual(decision, .ask(terminalID: "EA251683-CAB4-429D-A26C-3F074120F240"))
    }

    /// The glyph set belongs to the agent and changes; a rule that equals would break the
    /// first time Claude used a glyph nobody had written down here.
    func testADifferentGlyphInFrontChangesNothing() {
        let withOtherGlyph = [GhosttyTerminal(id: tabs[1].id, name: "✳ Следующие задачи по плану")]

        XCTAssertEqual(
            GhosttyFocus.decision(among: withOtherGlyph, sessionName: "Следующие задачи по плану"),
            .ask(terminalID: tabs[1].id)
        )
    }

    /// Two sessions can be given the same name by the agent, and then the name identifies
    /// neither. Moving a person to the wrong tab is worse than not moving them.
    func testTwoMatchesAreRefusedRatherThanGuessedBetween() {
        let twins = [
            GhosttyTerminal(id: "58E03558-BF80-475B-A933-10C473AA2812", name: "◐ Одно и то же имя"),
            GhosttyTerminal(id: "EA251683-CAB4-429D-A26C-3F074120F240", name: "✳ Одно и то же имя"),
        ]

        XCTAssertEqual(
            GhosttyFocus.decision(among: twins, sessionName: "Одно и то же имя"), .decline(.severalTabsMatch))
    }

    func testNothingMatchingIsSaidAsItself() {
        XCTAssertEqual(GhosttyFocus.decision(among: tabs, sessionName: "Что-то другое"), .decline(.noTabMatches))
    }

    /// The first minutes of a session, before the agent has named it. Temporary, and its own
    /// reason rather than "no match", because nothing is wrong and nothing needs fixing.
    func testASessionWithNoNameYetHasNothingToMatchOn() {
        XCTAssertEqual(GhosttyFocus.decision(among: tabs, sessionName: nil), .decline(.sessionHasNoName))
        XCTAssertEqual(GhosttyFocus.decision(among: tabs, sessionName: "   "), .decline(.sessionHasNoName))
    }

    /// An empty name would otherwise be a suffix of every tab, and the first one would win.
    func testAnEmptyNameDoesNotMatchEverything() {
        XCTAssertEqual(GhosttyFocus.decision(among: tabs, sessionName: ""), .decline(.sessionHasNoName))
    }

    /// The identifier is the one thing that ever reaches a script, so its shape is checked.
    /// The tab's name never does, which is why an agent's output cannot become a command.
    func testOnlyAUUIDCanBeWrittenIntoAScript() {
        XCTAssertTrue(GhosttyFocus.isAddressableTerminalID("EA251683-CAB4-429D-A26C-3F074120F240"))
        XCTAssertFalse(GhosttyFocus.isAddressableTerminalID("\" to quit -- "))
        XCTAssertFalse(GhosttyFocus.isAddressableTerminalID(""))
    }

    /// Only what a person can act on reaches the log; the ordinary case stays quiet.
    func testOnlyActionableRefusalsAreWorthALine() {
        XCTAssertEqual(JetBrainsFocusRefusal.notAJetBrainsIDE.attempt, .unaddressable)
        XCTAssertNotEqual(JetBrainsFocusRefusal.daemonMissing.attempt, .unaddressable)
        XCTAssertNotEqual(GhosttyFocusRefusal.noTabMatches.attempt, .unaddressable)
    }
}
