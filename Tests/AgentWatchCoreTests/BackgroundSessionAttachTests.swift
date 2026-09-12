import Foundation
import XCTest

@testable import AgentWatchCore

/// A background session has no window, but it has a door: `claude attach <job id>` opens it
/// in any terminal. These rules decide what is typed into that terminal, from what Claude Code
/// itself wrote down about the process.
final class BackgroundSessionAttachTests: XCTestCase {
    /// The shape of `~/.claude/sessions/<pid>.json` as measured on this machine.
    private let backgroundRecord = Data(
        """
        {"pid":"58778","sessionId":"3345bfdf-948a-49e2-9aef-24f7883a6605","kind":"bg",
         "jobId":"3345bfdf","name":"Следующие задачи по плану реализации","status":"idle"}
        """.utf8
    )

    func testTheJobIDIsReadFromTheProcesssOwnRecord() {
        XCTAssertEqual(BackgroundSessionAttach.jobID(inSessionRecord: backgroundRecord), "3345bfdf")
    }

    /// An interactive session has a record too, and no job: nothing to attach to.
    func testARecordWithoutAJobYieldsNothing() {
        let interactive = Data(#"{"pid":"46205","kind":"interactive","name":"chatgpt-history-export"}"#.utf8)
        XCTAssertNil(BackgroundSessionAttach.jobID(inSessionRecord: interactive))
        XCTAssertNil(BackgroundSessionAttach.jobID(inSessionRecord: Data("not json".utf8)))
    }

    /// The identifier is typed into a shell, so only a shape that cannot carry a command is
    /// allowed through — the same discipline `GhosttyFocus.isAddressableTerminalID` keeps.
    func testOnlyAPlainIdentifierIsTypedIntoAShell() {
        let unsafe = Data(#"{"jobId":"3345bfdf; rm -rf ~"}"#.utf8)
        XCTAssertNil(BackgroundSessionAttach.jobID(inSessionRecord: unsafe))
        XCTAssertNil(BackgroundSessionAttach.jobID(inSessionRecord: Data(#"{"jobId":""}"#.utf8)))
        XCTAssertNil(BackgroundSessionAttach.jobID(inSessionRecord: Data(#"{"jobId":"a b"}"#.utf8)))

        XCTAssertEqual(BackgroundSessionAttach.command(attaching: "3345bfdf"), "claude attach 3345bfdf")
        XCTAssertEqual(BackgroundSessionAttach.command(attaching: "job_1-A"), "claude attach job_1-A")
        XCTAssertNil(BackgroundSessionAttach.command(attaching: "3345bfdf\n"))
    }

    private let viewerTab = GhosttyTerminal(id: "D5B830AC-EA8D-4B8C-BF20-9E3FC3DE76C4", name: "claude attach 3345bfdf")
    private let staleTab = GhosttyTerminal(
        id: "EA251683-CAB4-429D-A26C-3F074120F240", name: "Следующие задачи по плану реализации")

    /// Pressing twice must not open the session twice. While a viewer runs, Ghostty titles its
    /// tab after the command it runs — measured — so that tab is the one to bring forward.
    func testAPressFindsTheTabAlreadyShowingTheSession() {
        XCTAssertEqual(
            BackgroundSessionAttach.decision(among: [staleTab, viewerTab], jobID: "3345bfdf", viewerIsRunning: true),
            .focus(terminalID: viewerTab.id)
        )
    }

    /// A title outlives the program that set it: measured, a tab whose shell had sat idle for
    /// a day still carried the session's name. With no viewer process behind it, a matching
    /// title is a memory of one, and the press opens a real viewer instead.
    func testATitleWithNoViewerBehindItIsNotTrusted() {
        XCTAssertEqual(
            BackgroundSessionAttach.decision(among: [viewerTab], jobID: "3345bfdf", viewerIsRunning: false),
            .openTab(typing: "claude attach 3345bfdf")
        )
    }

    func testWithNoTabToReuseANewOneIsOpened() {
        XCTAssertEqual(
            BackgroundSessionAttach.decision(among: [staleTab], jobID: "3345bfdf", viewerIsRunning: true),
            .openTab(typing: "claude attach 3345bfdf")
        )
        XCTAssertEqual(
            BackgroundSessionAttach.decision(among: [], jobID: "3345bfdf", viewerIsRunning: false),
            .openTab(typing: "claude attach 3345bfdf")
        )
    }

    /// Two viewers of the same job are both right, unlike two tabs sharing a session's *name*
    /// — the title here is the command with the job id in it — so the first is taken rather
    /// than a third one opened.
    func testTwoViewersOfTheSameJobAreBothRightAndTheFirstIsTaken() {
        let second = GhosttyTerminal(id: "0A60FB95-14FB-4B57-8848-751B1AD3EC7C", name: "claude attach 3345bfdf")
        XCTAssertEqual(
            BackgroundSessionAttach.decision(among: [viewerTab, second], jobID: "3345bfdf", viewerIsRunning: true),
            .focus(terminalID: second.id)
        )
    }

    func testAnIdentifierThatMayNotBeTypedIsRefusedBeforeAnyTabIsTouched() {
        XCTAssertEqual(
            BackgroundSessionAttach.decision(among: [viewerTab], jobID: "a b", viewerIsRunning: true),
            .decline
        )
    }

    func testTheRecordIsNamedAfterTheAgentProcess() {
        let home = URL(fileURLWithPath: "/Users/someone/.claude", isDirectory: true)
        XCTAssertEqual(
            BackgroundSessionAttach.sessionRecordURL(claudeHome: home, agentProcessID: 58778).path,
            "/Users/someone/.claude/sessions/58778.json"
        )
    }
}
