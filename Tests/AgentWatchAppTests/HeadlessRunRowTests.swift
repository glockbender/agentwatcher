import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// What a click on a headless run does: there is no window to raise, so it asks whether to end
/// the run, and a yes asks the run's process to stop (ADR-0021).
@MainActor
final class HeadlessRunRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Alive for as long as the test is, so the supervisor's exit watch does not close the
    /// row underneath the assertion.
    private let run = ProcessInfo.processInfo.processIdentifier

    func testAClickOnARunAsksToEndItAndSendsNothing() throws {
        var terminated: [Int32] = []
        let supervisor = makeSupervisor(terminated: { terminated.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "UserPromptSubmit", sessionID: "run", agentProcessID: run, clientKind: .headless))
        let row = try XCTUnwrap(supervisor.sessions.first)

        XCTAssertEqual(supervisor.reach(for: row), .headlessRun(.terminate(processID: run)))
        XCTAssertEqual(supervisor.focus(row), .asksToEndAgent(.terminate(processID: run)))
        XCTAssertEqual(terminated, [], "a click alone ends nothing")
    }

    /// The yes goes to the run's process, and the row goes with the run's end — not at the
    /// answer, and its end arriving again makes no row.
    func testYesAsksTheRunToStopAndItsRowGoesWithItsEnd() throws {
        var terminated: [Int32] = []
        let supervisor = makeSupervisor(terminated: { terminated.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "UserPromptSubmit", sessionID: "run", agentProcessID: run, clientKind: .headless))
        let row = try XCTUnwrap(supervisor.sessions.first)

        supervisor.endAgent(ofSessionWithID: row.id)

        XCTAssertEqual(terminated, [run])
        XCTAssertEqual(supervisor.sessions.map(\.id), [row.id], "still at work until it ends")

        supervisor.ingest(testRequest(event: "SessionEnd", sessionID: "run"))
        XCTAssertEqual(supervisor.sessions, [])
        supervisor.ingest(testRequest(event: "SessionEnd", sessionID: "run"))
        XCTAssertEqual(supervisor.sessions, [], "the late end came back as a closed row")
    }

    /// A number the kernel handed to a process younger than the run's last event is somebody
    /// else's: nothing is offered and nothing is sent.
    func testARunWhoseProcessIsSomebodyElsesOffersNothing() throws {
        var terminated: [Int32] = []
        var notes: [String] = []
        let supervisor = makeSupervisor(
            agentProcessStartedAt: { [now] _ in now + 60 }, terminated: { terminated.append($0) },
            notes: { notes.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "UserPromptSubmit", sessionID: "run", agentProcessID: run, clientKind: .headless))
        let row = try XCTUnwrap(supervisor.sessions.first)

        XCTAssertEqual(supervisor.reach(for: row), .headlessRun(nil))
        XCTAssertEqual(supervisor.focus(row), .nothingRaised)
        supervisor.endAgent(ofSessionWithID: row.id)

        XCTAssertEqual(terminated, [])
        XCTAssertTrue(notes.contains { $0.contains("nothing here can end it") }, "\(notes)")
    }

    func testTheCardSaysAClickAsksAndHowToDoItByHand() {
        let row = testSession(phase: .executing, clientKind: .headless, lastObservedAt: now)

        let card = hoverCardText(
            for: row, now: now, layout: .standard, reach: .headlessRun(.terminate(processID: 7220)))

        XCTAssertTrue(card.contains("Headless"), card)
        XCTAssertTrue(card.contains("A click asks to end it"), card)
        XCTAssertTrue(card.contains("kill 7220"), card)
        XCTAssertFalse(
            hoverCardText(for: row, now: now, layout: .standard, reach: .headlessRun(nil))
                .contains("A click asks to end it"))
    }

    /// The menu asks the same question, and says so on the line: the ellipsis is the menu's own
    /// way of saying a question follows.
    func testTheMenuLineOfARunLeadsToTheQuestion() {
        let row = testSession(title: "Nightly check", phase: .executing, clientKind: .headless, lastObservedAt: now)
        let everything = Set(SessionAttention.counted)

        let asks = menuSessionLines(
            for: [row], listing: everything, reach: { _ in .headlessRun(.terminate(processID: 7220)) })
        let cannot = menuSessionLines(for: [row], listing: everything, reach: { _ in .headlessRun(nil) })

        XCTAssertEqual(asks.map(\.title), ["Nightly check — headless run; end it…"])
        XCTAssertEqual(asks.map(\.leadsToQuestion), [true])
        XCTAssertEqual(cannot.map(\.title), ["Nightly check — headless run, nothing here can end it"])
        XCTAssertEqual(cannot.map(\.isEnabled), [false])
    }

    func testTheQuestionNamesARunAndWhatIsKept() {
        XCTAssertEqual(EndAgentDialog.heading(for: .headlessRun), "Headless run")
        XCTAssertEqual(
            EndAgentDialog.explanation(naming: "Nightly check", reason: .headlessRun),
            "“Nightly check”: a program started it, and it has no window. End it? Its transcript is kept.")
        XCTAssertEqual(
            EndAgentReason(for: testSession(clientKind: .headless, lastObservedAt: now)), .headlessRun)
        XCTAssertEqual(
            EndAgentReason(for: testSession(phase: .terminalClosed, clientKind: .cli, lastObservedAt: now)),
            .closedTerminal)
    }

    /// Never zero, one or a negative number, which `kill` reads as a group or as everything,
    /// and never this app.
    func testNothingButOneOtherProcessIsEverSignalled() {
        XCTAssertTrue(HeadlessRun.mayTerminate(7220, ownProcessID: 100))
        XCTAssertFalse(HeadlessRun.mayTerminate(0, ownProcessID: 100))
        XCTAssertFalse(HeadlessRun.mayTerminate(1, ownProcessID: 100))
        XCTAssertFalse(HeadlessRun.mayTerminate(-7220, ownProcessID: 100))
        XCTAssertFalse(HeadlessRun.mayTerminate(100, ownProcessID: 100))
    }

    private func makeSupervisor(
        agentProcessStartedAt: @escaping (Int32) -> Date? = { _ in .distantPast },
        terminated: @escaping (Int32) -> Void,
        notes: @escaping (String) -> Void = { _ in }
    ) -> SessionSupervisor {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SessionSupervisor(
            settings: WidgetSettingsStore(preferences: try! isolatedPreferences()),
            home: scratch.appendingPathComponent("home"),
            heard: AgentHeardStore(directoryURL: scratch.appendingPathComponent("heard")),
            history: SessionHistoryStore(directoryURL: scratch.appendingPathComponent("history")),
            now: { [now] in now },
            liveAgentProcesses: { [] },
            agentProcessStartedAt: agentProcessStartedAt,
            terminalState: { _ in .neverHad },
            terminate: { processID in
                terminated(processID)
                return true
            },
            focusHost: { _, _ in SessionHostRegistry.FocusOutcome(raised: false, tab: .unaddressable) },
            onChange: { _, _ in },
            onNotableEvent: notes
        )
    }
}
