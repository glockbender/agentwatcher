import AgentWatchCore
import AgentWatchLookup
import AgentWatchTestSupport
import AppKit
import Darwin
import XCTest

@testable import AgentWatchApp

/// What a row says and does once its session's terminal was closed with the agent left
/// behind — reported from a PyCharm tab on 2026-09-22, where the row sat nameless, said
/// `no signal`, and a click raised an IDE with no tab left to show.
@MainActor
final class ClosedTerminalRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Alive for as long as the test is, so the supervisor's exit watch does not close the
    /// row underneath the assertion.
    private let agent = ProcessInfo.processInfo.processIdentifier
    private let device = "/dev/ttys012"

    // MARK: - The lamp

    /// Red like a failure, because it is one a person has to deal with. Still rather than
    /// blinking: nothing is lost by waiting, and such a row can stand for days.
    func testTheLampReadsAsAFailureThatDoesNotBlink() {
        let look = SessionLamp.builtInAppearance(for: testSession(phase: .terminalClosed, lastObservedAt: now))

        XCTAssertEqual(look.name, "terminal closed")
        XCTAssertEqual(look.color.srgbHex, SessionPhase.failed.defaultLampStyle.color.srgbHex)
        XCTAssertEqual(look.motion, .steady)
        XCTAssertTrue(look.isFilled)
        XCTAssertEqual(SessionPhase.terminalClosed.settingsName, "Terminal closed")
    }

    // MARK: - Ending the agent

    /// `kill` is not the command: measured, neither `SIGTERM` nor `SIGKILL` gets the agent past
    /// the wait it is in. Discarding the output it waits on does, and `perl` is on every Mac.
    func testTheCommandOnTheCardDiscardsTheOutputTheAgentWaitsOn() {
        XCTAssertEqual(
            ClosedTerminal.releaseCommand(devicePath: device),
            #"perl -MPOSIX -e 'open(my $t, ">", $ARGV[0]) or die $!; tcflush(fileno($t), TCOFLUSH) or die $!' /dev/ttys012"#
        )
    }

    /// The path comes from another process's descriptors, and the app opens it for writing.
    func testNothingButATerminalDeviceIsEverOpened() {
        XCTAssertTrue(ClosedTerminal.isTerminalDevicePath("/dev/ttys012"))
        XCTAssertFalse(ClosedTerminal.isTerminalDevicePath("/dev/disk0"))
        XCTAssertFalse(ClosedTerminal.isTerminalDevicePath("/dev/ttys012/../disk0"))
        XCTAssertFalse(ClosedTerminal.isTerminalDevicePath("/Users/somebody/.zshrc"))
        XCTAssertFalse(ClosedTerminal.isTerminalDevicePath("/dev/ttys"))
        XCTAssertFalse(ClosedTerminal.discardUnreadOutput(devicePath: "/dev/disk0"))
    }

    /// The same flush the app does on a click, against a terminal whose other end reads
    /// nothing — which is exactly the state a closed JetBrains tab leaves behind.
    func testDiscardingTheUnreadOutputEmptiesTheTerminal() throws {
        var controller: Int32 = -1
        var terminal: Int32 = -1
        XCTAssertEqual(openpty(&controller, &terminal, nil, nil, nil), 0)
        defer {
            close(controller)
            close(terminal)
        }
        let path = try XCTUnwrap(ttyname(terminal).map { String(cString: $0) })
        XCTAssertEqual(write(terminal, "never read", 10), 10)

        XCTAssertTrue(ClosedTerminal.discardUnreadOutput(devicePath: path))

        _ = fcntl(controller, F_SETFL, fcntl(controller, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(read(controller, &buffer, buffer.count), -1, "the output should be gone")
        XCTAssertEqual(errno, EAGAIN)
    }

    // MARK: - The card

    func testTheCardSaysAClickEndsItAndHowToDoItByHand() {
        let row = testSession(phase: .terminalClosed, clientKind: .cli, lastObservedAt: now)

        let card = hoverCardText(
            for: row, now: now, layout: .standard, reach: .closedTerminal(.discardOutput(devicePath: device)))

        XCTAssertTrue(card.contains("terminal closed"), card)
        XCTAssertTrue(card.contains("A click asks to end it"), card)
        XCTAssertTrue(card.contains(ClosedTerminal.releaseCommand(devicePath: device)), card)
    }

    /// Without a device there is nothing to discard, and the card must not promise a click
    /// that will do nothing.
    func testWithNoDeviceTheCardPromisesNothing() {
        let row = testSession(phase: .terminalClosed, clientKind: .cli, lastObservedAt: now)

        let card = hoverCardText(for: row, now: now, layout: .standard, reach: .closedTerminal(nil))

        XCTAssertFalse(card.contains("A click asks to end it"), card)
        XCTAssertFalse(card.contains("perl"), card)
    }

    // MARK: - Finding it

    /// The reported case: the app restarted, found the agent still running with nothing
    /// heard from it, and built a row out of the process.
    func testARowBuiltFromTheProcessIsMarkedWhenItsTerminalIsGone() throws {
        var notes: [String] = []
        let supervisor = makeSupervisor(
            processes: [DiscoveredAgentProcess(source: .claude, processID: agent, startedAt: now, projectName: "devx")],
            terminalState: { _ in .lost },
            notes: { notes.append($0) }
        )
        supervisor.start()
        defer { supervisor.stop() }

        XCTAssertEqual(try XCTUnwrap(supervisor.sessions.first).phase, .terminalClosed)
        XCTAssertTrue(notes.contains { $0.contains("terminal closed") }, "\(notes)")
    }

    /// The same for a session that spoke: until the restart, the reported row was one of these.
    func testASessionThatSpokeIsMarkedByTheNextScanAfterItsTerminalWent() throws {
        var state = AgentProcessLocator.TerminalState.attached
        let supervisor = makeSupervisor(terminalState: { _ in state })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        XCTAssertEqual(try XCTUnwrap(supervisor.sessions.first).phase, .idle)

        state = .lost
        supervisor.discoverAgentProcesses()

        XCTAssertEqual(try XCTUnwrap(supervisor.sessions.first).phase, .terminalClosed)
    }

    // MARK: - The click

    /// A click on a broken session ends nothing by itself: it asks, and names the way the
    /// agent would be ended. The yes is what ends it.
    func testAClickOnAMarkedRowAsksAndOnlyTheYesEndsTheAgent() throws {
        var released: [String] = []
        let supervisor = makeSupervisor(terminalState: { _ in .lost }, released: { released.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.discoverAgentProcesses()
        let row = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(row.phase, .terminalClosed)
        XCTAssertEqual(supervisor.reach(for: row), .closedTerminal(.discardOutput(devicePath: device)))

        XCTAssertEqual(supervisor.focus(row), .asksToEndAgent(.discardOutput(devicePath: device)))
        XCTAssertEqual(released, [], "the click only asks")

        supervisor.endAgent(ofSessionWithID: row.id)

        XCTAssertEqual(released, [device])
    }

    /// The first click on a row still drawn as an ordinary session finds out, marks it and
    /// asks at once: a second click to reach the question was the complaint.
    func testTheFirstClickOnARowNotMarkedYetMarksItAndAsks() throws {
        var state = AgentProcessLocator.TerminalState.attached
        var released: [String] = []
        let supervisor = makeSupervisor(terminalState: { _ in state }, released: { released.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        state = .lost

        XCTAssertEqual(
            supervisor.focus(try XCTUnwrap(supervisor.sessions.first)),
            .asksToEndAgent(.discardOutput(devicePath: device)),
            "the IDE is not raised either"
        )

        XCTAssertEqual(try XCTUnwrap(supervisor.sessions.first).phase, .terminalClosed)
        XCTAssertEqual(released, [])
    }

    /// Nothing is asked that a yes could not carry out.
    func testWithNoWayToEndTheAgentTheClickAsksNothing() throws {
        let supervisor = makeSupervisor(terminalState: { _ in .neverHad })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        let marked = try XCTUnwrap(
            supervisor.sessions.first.map { snapshot -> SessionSnapshot in
                var closed = snapshot
                closed.phase = .terminalClosed
                return closed
            })

        XCTAssertEqual(supervisor.focus(marked), .nothingRaised)
    }

    /// Asked again at the answer rather than trusted from the click: by then the process may
    /// be gone and its terminal handed to somebody's new tab.
    func testAYesFlushesNothingOnceTheProcessNoLongerLostItsTerminal() throws {
        var state = AgentProcessLocator.TerminalState.lost
        var released: [String] = []
        var hungUp: [[Int32]] = []
        let supervisor = makeSupervisor(
            terminalState: { _ in state }, released: { released.append($0) }, hungUp: { hungUp.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.discoverAgentProcesses()
        let row = try XCTUnwrap(supervisor.sessions.first)
        supervisor.focus(row)

        state = .attached
        supervisor.endAgent(ofSessionWithID: row.id)

        XCTAssertEqual(released, [])
        XCTAssertEqual(hungUp, [], "a terminal the agent has again is not a tab Ghostty closed")
    }

    /// The row goes once its agent has — and not at the answer: a row taken away at once
    /// would hide an agent the ending did not end. The agent's own last hook, arriving after
    /// the row went, brings nothing back.
    func testAYesTakesTheRowAwayOnceTheAgentHasEnded() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        var notes: [String] = []
        let supervisor = makeSupervisor(
            terminalState: { _ in .lost },
            released: { _ in child.terminate() },
            notes: { notes.append($0) }
        )
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(
                event: "SessionStart", sessionID: "devx", agentProcessID: child.processIdentifier, clientKind: .cli))
        supervisor.discoverAgentProcesses()
        let row = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(row.phase, .terminalClosed)

        supervisor.endAgent(ofSessionWithID: row.id)
        let deadline = Date().addingTimeInterval(5)
        while !supervisor.sessions.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(supervisor.sessions, [], "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("ended as asked; session removed") }, "\(notes)")

        supervisor.ingest(testRequest(event: "SessionEnd", sessionID: "devx"))

        XCTAssertEqual(supervisor.sessions, [], "the late end came back as a closed row")
    }

    /// An ending that went out and did not end the agent leaves the row as it was, and the
    /// next click asks again.
    func testAnAgentTheYesDidNotEndKeepsItsRow() throws {
        var released: [String] = []
        let supervisor = makeSupervisor(terminalState: { _ in .lost }, released: { released.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.discoverAgentProcesses()
        let row = try XCTUnwrap(supervisor.sessions.first)

        supervisor.endAgent(ofSessionWithID: row.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(released, [device])
        XCTAssertEqual(try XCTUnwrap(supervisor.sessions.first).phase, .terminalClosed)
        XCTAssertEqual(
            supervisor.focus(try XCTUnwrap(supervisor.sessions.first)),
            .asksToEndAgent(.discardOutput(devicePath: device)))
    }

    /// The same last hook, arriving before the agent's exit is seen: the row it closes is
    /// taken away too, instead of standing as a finished session.
    func testAnEndReportedBeforeTheExitAlsoTakesTheRowAway() throws {
        let supervisor = makeSupervisor(terminalState: { _ in .lost })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.discoverAgentProcesses()
        supervisor.endAgent(ofSessionWithID: try XCTUnwrap(supervisor.sessions.first).id)

        supervisor.ingest(testRequest(event: "SessionEnd", sessionID: "devx"))

        XCTAssertEqual(supervisor.sessions, [])
    }

    func testAMenuClickDoesNotEndAnAgentUnlessTheDisplayedLineAnnouncedIt() throws {
        var state = AgentProcessLocator.TerminalState.attached
        var released: [String] = []
        var notes: [String] = []
        let supervisor = makeSupervisor(
            terminalState: { _ in state }, released: { released.append($0) }, notes: { notes.append($0) })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "UserPromptSubmit", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        let ordinary = try XCTUnwrap(
            menuSessionLines(
                for: supervisor.sessions, listing: Set(SessionAttention.counted), reach: supervisor.reach(for:)
            ).first)

        state = .lost
        supervisor.discoverAgentProcesses()
        XCTAssertEqual(try XCTUnwrap(supervisor.sessions.first).phase, .terminalClosed)
        supervisor.focusSession(id: ordinary.sessionID, endingAgentWasAnnounced: ordinary.endingAgentWasAnnounced)
        XCTAssertEqual(released, [], "a change since the menu opened must not turn focus into terminal release")

        let announced = try XCTUnwrap(
            menuSessionLines(
                for: supervisor.sessions, listing: Set(SessionAttention.counted), reach: supervisor.reach(for:)
            ).first)
        XCTAssertTrue(announced.title.contains("click ends the agent"))
        supervisor.focusSession(id: announced.sessionID, endingAgentWasAnnounced: announced.endingAgentWasAnnounced)
        XCTAssertEqual(released, [device])

        supervisor.ingest(testRequest(event: "SessionEnd", sessionID: "devx"))
        XCTAssertEqual(supervisor.sessions, [], "the line's click is the widget's yes, row and all")
        supervisor.focusSession(id: announced.sessionID, endingAgentWasAnnounced: true)
        XCTAssertEqual(released, [device], "an old announced action must still check the current session")
        XCTAssertTrue(notes.contains { $0.contains("gone before the click") }, "said, not swallowed: \(notes)")
        supervisor.focusSession(id: "gone", endingAgentWasAnnounced: true)
        XCTAssertEqual(released, [device])
    }

    // MARK: - A tab Ghostty closed and kept

    /// Reported on 2026-09-29: a person closed a Ghostty tab, Ghostty kept the terminal
    /// behind it with the agent running, and a click on the row brought forward whichever
    /// Ghostty window was in front — an empty shell.
    /// The shell the agent was typed into and the `login` above it, as the kernel's walk up
    /// the agent's terminal would find them.
    private let shell: Int32 = 52482
    private let login: Int32 = 52480
    private let tabGone = SessionHostRegistry.FocusOutcome(
        raised: false, tab: .gone("Ghostty holds 5 terminals and shows 4, none named after this session"))

    func testAClickThatFindsItsTabGoneMarksTheRowAndAsks() throws {
        var hungUp: [[Int32]] = []
        var notes: [String] = []
        let supervisor = makeSupervisor(
            terminalState: { _ in .attached },
            notes: { notes.append($0) },
            hungUp: { hungUp.append($0) },
            focusHost: { [tabGone] _, _ in tabGone }
        )
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))

        XCTAssertEqual(
            supervisor.focus(try XCTUnwrap(supervisor.sessions.first)),
            .asksToEndAgent(.hangUp(processIDs: [agent, shell, login])),
            "no window comes forward"
        )

        XCTAssertEqual(try XCTUnwrap(supervisor.sessions.first).phase, .terminalClosed)
        XCTAssertEqual(hungUp, [], "the click only asks")
        XCTAssertTrue(notes.contains { $0.contains("Ghostty holds 5 terminals and shows 4") }, "\(notes)")
    }

    /// The card is drawn on hover, and a hover sends Ghostty nothing: which ending applies is
    /// read from the kernel, where the agent still has its terminal.
    func testTheCardOfARowWhoseTabIsGoneOffersAHangUp() throws {
        let supervisor = makeSupervisor(terminalState: { _ in .attached }, focusHost: { [tabGone] _, _ in tabGone })
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.focus(try XCTUnwrap(supervisor.sessions.first))
        let row = try XCTUnwrap(supervisor.sessions.first)

        let reach = supervisor.reach(for: row)
        let card = hoverCardText(for: row, now: now, layout: .standard, reach: reach)

        XCTAssertEqual(reach, .closedTerminal(.hangUp(processIDs: [agent, shell, login])))
        XCTAssertTrue(card.contains("A click asks to end it and its shell"), card)
        XCTAssertTrue(card.contains("kill -HUP \(agent) \(shell) \(login)"), card)
    }

    func testAYesHangsUpTheAgentWhileItsTabIsStillGone() throws {
        var hungUp: [[Int32]] = []
        let supervisor = makeSupervisor(
            terminalState: { _ in .attached },
            agentProcessStartedAt: { [now] _ in now.addingTimeInterval(-60) },
            hungUp: { hungUp.append($0) },
            focusHost: { [tabGone] _, _ in tabGone },
            tabIsGone: { _, _ in true }
        )
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.focus(try XCTUnwrap(supervisor.sessions.first))
        supervisor.focus(try XCTUnwrap(supervisor.sessions.first))
        XCTAssertEqual(hungUp, [], "a second click asks again, and still ends nothing")

        supervisor.endAgent(ofSessionWithID: try XCTUnwrap(supervisor.sessions.first).id)

        XCTAssertEqual(hungUp, [[agent, shell, login]], "the agent first, then what its closed tab ran it in")
    }

    /// Asked again at the answer: the tab may be back, or Ghostty may have let the terminal
    /// go and the count with it.
    func testAYesSendsNothingOnceTheTabIsNoLongerMissing() throws {
        var hungUp: [[Int32]] = []
        let supervisor = makeSupervisor(
            terminalState: { _ in .attached },
            agentProcessStartedAt: { [now] _ in now.addingTimeInterval(-60) },
            hungUp: { hungUp.append($0) },
            focusHost: { [tabGone] _, _ in tabGone },
            tabIsGone: { _, _ in false }
        )
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.focus(try XCTUnwrap(supervisor.sessions.first))

        supervisor.endAgent(ofSessionWithID: try XCTUnwrap(supervisor.sessions.first).id)

        XCTAssertEqual(hungUp, [])
    }

    /// A process that started after the row last heard from its agent is somebody else under
    /// a number handed out again, and a hang-up would end a stranger.
    func testAYesSendsNothingToAProcessNewerThanTheRow() throws {
        var hungUp: [[Int32]] = []
        let supervisor = makeSupervisor(
            terminalState: { _ in .attached },
            agentProcessStartedAt: { [now] _ in now.addingTimeInterval(60) },
            hungUp: { hungUp.append($0) },
            focusHost: { [tabGone] _, _ in tabGone },
            tabIsGone: { _, _ in true }
        )
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "devx", agentProcessID: agent, clientKind: .cli))
        supervisor.focus(try XCTUnwrap(supervisor.sessions.first))

        supervisor.endAgent(ofSessionWithID: try XCTUnwrap(supervisor.sessions.first).id)

        XCTAssertEqual(hungUp, [])
    }

    // MARK: - Scaffolding

    /// Nothing here reaches a real host: the process running the tests may be in a Ghostty
    /// tab, and the registry would ask that Ghostty.
    private func makeSupervisor(
        processes: [DiscoveredAgentProcess] = [],
        terminalState: @escaping (Int32) -> AgentProcessLocator.TerminalState?,
        agentProcessStartedAt: @escaping (Int32) -> Date? = { _ in nil },
        released: @escaping (String) -> Void = { _ in },
        notes: @escaping (String) -> Void = { _ in },
        hungUp: @escaping ([Int32]) -> Void = { _ in },
        focusHost: @escaping (SessionSnapshot, [String]) -> SessionHostRegistry.FocusOutcome = { _, _ in
            SessionHostRegistry.FocusOutcome(raised: false, tab: .unaddressable)
        },
        tabIsGone: @escaping (SessionSnapshot, [String]) -> Bool = { _, _ in false }
    ) -> SessionSupervisor {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return SessionSupervisor(
            settings: WidgetSettingsStore(preferences: try! isolatedPreferences()),
            home: scratch.appendingPathComponent("home"),
            heard: AgentHeardStore(directoryURL: scratch.appendingPathComponent("heard")),
            history: SessionHistoryStore(directoryURL: scratch.appendingPathComponent("history")),
            now: { [now] in now },
            liveAgentProcesses: { processes },
            agentProcessStartedAt: agentProcessStartedAt,
            terminalState: terminalState,
            terminalDevicePath: { [device] _ in device },
            releaseTerminal: { path in
                released(path)
                return true
            },
            terminalProcessChain: { [shell, login] processID in [processID, shell, login] },
            hangUp: { processIDs in
                hungUp(processIDs)
                return true
            },
            focusHost: focusHost,
            tabIsGoneWithTerminalKept: tabIsGone,
            onChange: { _, _ in },
            onNotableEvent: notes
        )
    }
}
