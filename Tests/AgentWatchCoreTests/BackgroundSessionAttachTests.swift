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

    /// `/bg` leaves the terminal it was typed in attached to the job: the interactive process
    /// stays alive, its own record names the job in `parkedJobId`, and the session is on screen
    /// there. Measured on 2.1.269: the record of the terminal that parked job `b95a16c1` carried
    /// `"kind":"interactive","parkedJobId":"b95a16c1"`, and no `claude attach` process existed.
    /// That terminal is the session's window, and a click must reach it rather than open a
    /// second one.
    func testTheTerminalThatParkedTheJobIsItsViewer() {
        let parked = Data(
            #"{"pid":81685,"kind":"interactive","name":"agent-watch-31","parkedJobId":"b95a16c1"}"#.utf8)
        let other = Data(#"{"pid":30515,"kind":"interactive","name":"x","parkedJobId":"23f9286d"}"#.utf8)
        let job = Data(#"{"pid":16222,"kind":"bg","jobId":"b95a16c1"}"#.utf8)

        let viewer = BackgroundSessionAttach.viewerProcessID(
            ofJob: "b95a16c1",
            inSessionRecords: [other, job, parked],
            isProcessAlive: { _, _ in true }
        )

        XCTAssertEqual(viewer, 81685)
    }

    /// A record outlives its process — the file is not removed on exit — so a parked terminal
    /// whose process is gone is no viewer, and the click falls back to `claude attach`.
    func testAParkedTerminalWhoseProcessIsGoneIsNoViewer() {
        let parked = Data(#"{"pid":81685,"kind":"interactive","parkedJobId":"b95a16c1"}"#.utf8)

        let viewer = BackgroundSessionAttach.viewerProcessID(
            ofJob: "b95a16c1",
            inSessionRecords: [parked],
            isProcessAlive: { _, _ in false }
        )

        XCTAssertNil(viewer)
    }

    /// The job's own record says `jobId`, never `parkedJobId`; a background process is not a
    /// viewer of itself. And the number is read as Claude Code writes it — a number — as well as
    /// the quoted spelling older records used.
    func testOnlyAnInteractiveRecordNamingTheJobAsParkedCounts() {
        let job = Data(#"{"pid":16222,"kind":"bg","jobId":"b95a16c1","parkedJobId":"b95a16c1"}"#.utf8)
        let quoted = Data(#"{"pid":"4242","kind":"interactive","parkedJobId":"b95a16c1"}"#.utf8)

        XCTAssertNil(
            BackgroundSessionAttach.viewerProcessID(
                ofJob: "b95a16c1", inSessionRecords: [job], isProcessAlive: { _, _ in true }))
        XCTAssertEqual(
            BackgroundSessionAttach.viewerProcessID(
                ofJob: "b95a16c1", inSessionRecords: [quoted, Data("not json".utf8)], isProcessAlive: { _, _ in true }),
            4_242)
    }

    /// The record carries two readings of the start: `procStart`, the kernel's own, as a UTC
    /// date in `ctime` spelling — a single-digit day padded with a space, `Wed Sep  2` — and
    /// `startedAt`, Claude Code's clock a few seconds later (measured 0–3 s behind on eight
    /// records). The kernel's is the exact quantity and nothing rewrites it, so it is the one
    /// handed to the liveness check when it is there.
    func testTheKernelsOwnReadingOfTheStartIsPreferred() {
        let parked = Data(
            #"""
            {"pid":81685,"kind":"interactive","parkedJobId":"b95a16c1",
             "procStart":"Sat Sep 12 09:53:31 2026","startedAt":1789206871829}
            """#.utf8)
        let earlyInTheMonth = Data(
            #"{"pid":81686,"kind":"interactive","parkedJobId":"b95a16c1","procStart":"Wed Sep  2 09:53:31 2026"}"#.utf8)
        let older = Data(#"{"pid":4242,"kind":"interactive","parkedJobId":"b95a16c1","startedAt":1789206871829}"#.utf8)
        var starts: [Int32: Date?] = [:]

        for record in [parked, earlyInTheMonth, older] {
            _ = BackgroundSessionAttach.viewerProcessID(ofJob: "b95a16c1", inSessionRecords: [record]) {
                starts[$0] = $1
                return true
            }
        }

        XCTAssertEqual(starts[81685], Date(timeIntervalSince1970: 1_789_206_811), "2026-09-12T09:53:31Z")
        XCTAssertEqual(starts[81686], Date(timeIntervalSince1970: 1_788_342_811), "2026-09-02T09:53:31Z, padded")
        XCTAssertEqual(
            starts[4242], Date(timeIntervalSince1970: 1_789_206_871.829), "from `startedAt` when that is all")
    }

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
    /// — the title here is the command with the job id in it — so one is taken rather than a
    /// third opened: the one Ghostty lists first, which is its own order, the order the tabs
    /// were opened in. Not the smaller identifier, which is a UUID and therefore no order at all.
    func testTwoViewersOfTheSameJobAreBothRightAndTheFirstListedIsTaken() {
        let second = GhosttyTerminal(id: "0A60FB95-14FB-4B57-8848-751B1AD3EC7C", name: "claude attach 3345bfdf")
        XCTAssertEqual(
            BackgroundSessionAttach.decision(among: [viewerTab, second], jobID: "3345bfdf", viewerIsRunning: true),
            .focus(terminalID: viewerTab.id)
        )
    }

    /// `claude attach -x` is an option, not a job. The shell reads nothing special in a dash,
    /// but the program does, and the guard's promise is a shape that cannot carry anything.
    func testAnIdentifierShapedLikeAnOptionIsRefused() {
        XCTAssertFalse(BackgroundSessionAttach.isAddressableJobID("-x"))
        XCTAssertNil(BackgroundSessionAttach.command(attaching: "--help"))
        XCTAssertTrue(BackgroundSessionAttach.isAddressableJobID("job-1"))
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
