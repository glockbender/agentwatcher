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

    // MARK: - A tab Ghostty closed and kept

    /// What Ghostty 1.3.1 listed on 2026-09-29 after a person closed the tab of the session
    /// "Документация проекта": four terminals, while it held five — the fifth still running
    /// that session's agent.
    private let listedAfterTheClose = [
        GhosttyTerminal(id: "58E03558-BF80-475B-A933-10C473AA2812", name: "◑ Slack thread C077SKJ47NF troubleshooting"),
        GhosttyTerminal(
            id: "54175EB0-B04C-4DB9-B918-52A6C5826FF2", name: "✳ JetBrains плагин локальная установка и обновление"),
        GhosttyTerminal(id: "F28AD113-FE5F-4950-A28F-1AC92DC25B58", name: "~/CommonProjects/agent-watch"),
        GhosttyTerminal(
            id: "0CE0F8D7-20D4-4B91-AD78-BE4A9E9BF687", name: "◐ Имя сессии из транскрипта вместо терминала"),
    ]

    func testATabGoneWhileGhosttyKeepsItsTerminalIsToldApartFromAMissingName() {
        let decision = GhosttyFocus.decision(
            among: listedAfterTheClose,
            sessionName: "Документация проекта",
            heldTerminalCount: 5,
            otherSessionNames: ["Имя сессии из транскрипта вместо терминала"]
        )

        XCTAssertEqual(decision, .decline(.tabClosedTerminalKept(held: 5, shown: 4)))
    }

    /// Every terminal Ghostty holds is listed, so this session's tab is one of them under a
    /// title that does not carry its name — overwritten, or never written.
    func testWithEveryHeldTerminalListedAMissingNameIsOnlyThat() {
        let decision = GhosttyFocus.decision(
            among: listedAfterTheClose,
            sessionName: "Документация проекта",
            heldTerminalCount: 4,
            otherSessionNames: ["Имя сессии из транскрипта вместо терминала"]
        )

        XCTAssertEqual(decision, .decline(.noTabMatches))
    }

    /// The first report of a nameless tab was a machine with `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`
    /// set: no tab carries any session's name there, and a terminal kept by an earlier close
    /// keeps the count above the list for as long as Ghostty runs. Titles have to be shown to
    /// work before a missing one means a missing tab — otherwise every click there would mark
    /// a live session and offer to end it.
    func testWhereNoTabCarriesAnySessionsNameAMissingOneProvesNothing() {
        let untitled = listedAfterTheClose.map { GhosttyTerminal(id: $0.id, name: "claude") }

        let decision = GhosttyFocus.decision(
            among: untitled,
            sessionName: "Документация проекта",
            heldTerminalCount: 5,
            otherSessionNames: ["Имя сессии из транскрипта вместо терминала"]
        )

        XCTAssertEqual(decision, .decline(.noTabMatches))
    }

    /// A blank name of another session proves nothing either: every title ends with an empty
    /// string, and taken as a name it would make every missing tab a gone one.
    func testABlankNameOfAnotherSessionProvesNothing() {
        let untitled = listedAfterTheClose.map { GhosttyTerminal(id: $0.id, name: "claude") }

        let decision = GhosttyFocus.decision(
            among: untitled, sessionName: "Документация проекта", heldTerminalCount: 5,
            otherSessionNames: ["", "   "])

        XCTAssertEqual(decision, .decline(.noTabMatches))
    }

    /// Found tabs are focused whatever the count says: a terminal kept by an earlier close
    /// must not stop every other session from being reached.
    func testAFoundTabIsFocusedWhateverGhosttyHolds() {
        let decision = GhosttyFocus.decision(
            among: listedAfterTheClose,
            sessionName: "Имя сессии из транскрипта вместо терминала",
            heldTerminalCount: 5,
            otherSessionNames: ["JetBrains плагин локальная установка и обновление"]
        )

        XCTAssertEqual(decision, .ask(terminalID: "0CE0F8D7-20D4-4B91-AD78-BE4A9E9BF687"))
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
        XCTAssertEqual(
            GhosttyFocusRefusal.tabClosedTerminalKept(held: 5, shown: 4).attempt,
            .gone("Ghostty holds 5 terminals and shows 4, none named after this session")
        )
    }
}
