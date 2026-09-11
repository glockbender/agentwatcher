import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The half of "a live agent is a session" that the engine cannot hold: what the application
/// does with such a row — when it looks for one, what the dismiss button means for it, and
/// what a row that never was a session says about itself.
@MainActor
final class DiscoveredProcessRowTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 3_000)
    private let now = Date(timeIntervalSince1970: 4_000)

    /// The plan's case: the app was launched after the agent, so the widget would be empty
    /// until a session that may be waiting for a person takes its next turn.
    func testAnAgentRunningBeforeTheAppStartedGetsARowAtLaunch() throws {
        let supervisor = try makeSupervisor(processes: [running(id: 4_242)])

        supervisor.start()
        defer { supervisor.stop() }

        let row = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(supervisor.sessions.count, 1)
        XCTAssertEqual(row.phase, .disconnected)
        XCTAssertEqual(row.projectName, "agent-watch")
        XCTAssertEqual(row.lastObservedAt, started)
        XCTAssertNotNil(row.discoveredProcess)
    }

    /// Dismissing is the only way such a row can be wrong for a person, so it has to stick.
    /// The next scan finds the same process again, and without this the button would be the
    /// one control in the widget that does nothing.
    func testADismissedRowDoesNotComeBackOnTheNextScan() throws {
        let supervisor = try makeSupervisor(processes: [running(id: 4_242)])
        supervisor.start()
        defer { supervisor.stop() }

        supervisor.remove(try XCTUnwrap(supervisor.sessions.first))
        supervisor.discoverAgentProcesses()

        XCTAssertEqual(supervisor.sessions, [])
    }

    /// The same button on a row that is a real session, whose agent is still running.
    ///
    /// A row can be dismissed while it says `no signal`, while it carries a fault, or after
    /// half an hour of silence, and the agent can be alive through all three. Only rows built
    /// from a process used to be remembered as dismissed, so the next scan rebuilt this one —
    /// and once a pairing could name it, it came back looking exactly like the row that had
    /// just been dismissed.
    func testDismissingASessionWhoseAgentStillRunsAlsoSticks() throws {
        let supervisor = try makeSupervisor(
            processes: [running(id: 4_242)],
            agentProcessStartedAt: { [started] _ in started }
        )
        supervisor.start()
        defer { supervisor.stop() }
        supervisor.ingest(request(event: "SessionStart", sessionID: "alpha", agentProcessID: 4_242))
        let session = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertNil(session.discoveredProcess, "this is a session that spoke, not a row built from a process")

        supervisor.remove(session)
        supervisor.discoverAgentProcesses()

        XCTAssertEqual(supervisor.sessions, [], "the agent is still running, and the answer about it stands")
    }

    /// The row is not a session that ended — it never was more than the process it named.
    /// Closing it would leave a tombstone for a session nobody ever saw anything about, and
    /// under "remove closed sessions by hand" that tombstone would stay until dismissed.
    func testAnAgentThatQuitsTakesItsRowAwayRatherThanClosingIt() throws {
        var processes = [running(id: 4_242)]
        let supervisor = try makeSupervisor(processes: { processes })
        supervisor.start()
        defer { supervisor.stop() }
        XCTAssertEqual(supervisor.sessions.count, 1)

        processes = []
        supervisor.discoverAgentProcesses()

        XCTAssertEqual(supervisor.sessions, [], "a row nobody heard from leaves no tombstone")
    }

    /// The join, through the application rather than the engine: a hook carrying the same
    /// process number turns the row into the session it always was, and there is one row
    /// afterwards rather than two.
    func testTheFirstHookFromADiscoveredAgentReplacesItsRow() throws {
        let supervisor = try makeSupervisor(processes: [running(id: 4_242)])
        supervisor.start()
        defer { supervisor.stop() }
        let discovered = try XCTUnwrap(supervisor.sessions.first)

        supervisor.ingest(request(event: "SessionStart", sessionID: "alpha", agentProcessID: 4_242))

        let session = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(supervisor.sessions.count, 1)
        XCTAssertNil(session.discoveredProcess)
        XCTAssertEqual(session.arrivalIndex, discovered.arrivalIndex, "the session keeps the row's place")
        XCTAssertEqual(session.phase, .idle)
    }

    /// Such a row is written nowhere: the next launch looks for the process again, and a
    /// remembered copy could only bring back a row for an agent that has since exited.
    func testADiscoveredRowIsNotRememberedForTheNextLaunch() throws {
        let directory = try makeDirectory()
        let settings = try makeSettings()
        let firstLaunch = try makeSupervisor(
            processes: [running(id: 4_242)],
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        firstLaunch.start()
        firstLaunch.stop()

        let secondLaunch = try makeSupervisor(
            processes: [],
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        XCTAssertEqual(secondLaunch.sessions, [])
    }

    /// What the row is written down as instead: which session its process belongs to.
    ///
    /// A session's record leaves the app long before its agent stops running — the row is
    /// dismissed by hand, or swept after a silence — and then only the process is left. The
    /// pairing its first hook stated is the one honest way back to the session, and a
    /// recognised process is that session rather than a stranger with the same number.
    func testARunningProcessIsRecognisedAsTheSessionAHookSaidItWas() throws {
        let directory = try makeDirectory()
        let settings = try makeSettings()
        let firstLaunch = try makeSupervisor(
            processes: [running(id: 4_242)],
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            agentProcessStartedAt: { [started] _ in started }
        )
        firstLaunch.start()
        firstLaunch.ingest(request(event: "SessionStart", sessionID: "alpha", agentProcessID: 4_242))
        let session = try XCTUnwrap(firstLaunch.sessions.first)
        firstLaunch.remove(session)
        firstLaunch.stop()

        let secondLaunch = try makeSupervisor(
            processes: [running(id: 4_242)],
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            agentProcessStartedAt: { [started] _ in started }
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        XCTAssertEqual(secondLaunch.sessions.map(\.id), [session.id], "the same session, found by its process")
        XCTAssertNotNil(
            secondLaunch.sessions.first?.discoveredProcess,
            "recognising a session is not the same as hearing from it"
        )

        // And the moment it does speak, it is a session like any other — one the file keeps.
        secondLaunch.ingest(request(event: "SessionStart", sessionID: "alpha", agentProcessID: 4_242))

        XCTAssertNil(secondLaunch.sessions.first?.discoveredProcess)
        XCTAssertEqual(SessionHistoryStore(directoryURL: directory).remembered.map(\.id), [session.id])
    }

    /// The pairing names one run of one process, so a scan that no longer sees that process
    /// forgets it — on disk as well, or the list would be the one thing here that only grows.
    func testAPairingIsForgottenOnceItsProcessIsGone() throws {
        let directory = try makeDirectory()
        let settings = try makeSettings()
        let firstLaunch = try makeSupervisor(
            processes: [running(id: 4_242)],
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            agentProcessStartedAt: { [started] _ in started }
        )
        firstLaunch.start()
        firstLaunch.ingest(request(event: "SessionStart", sessionID: "alpha", agentProcessID: 4_242))
        firstLaunch.remove(try XCTUnwrap(firstLaunch.sessions.first))
        firstLaunch.stop()
        XCTAssertEqual(SessionHistoryStore(directoryURL: directory).rememberedAgentProcesses.count, 1)

        // The agent quits, and the next launch sees nothing running under that number.
        let secondLaunch = try makeSupervisor(
            processes: [],
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        secondLaunch.start()
        secondLaunch.stop()

        XCTAssertEqual(
            SessionHistoryStore(directoryURL: directory).rememberedAgentProcesses,
            [],
            "nothing is running under that name any more, so nothing is remembered about it"
        )
    }

    /// A row with nothing but a lamp says less than nothing, so any row without a name shows
    /// the directory instead — whether the app heard about it from a hook or found it by its
    /// process.
    ///
    /// Only the row built from a process used to do this. A session that has started and is
    /// waiting at its prompt was seen sitting in the widget with no name for minutes: the
    /// name arrives when the person asks it something, and until then there is nothing to
    /// arrive.
    ///
    /// Shown as a stand-in and said to be one: a bare directory reads as a name the agent
    /// chose, and two sessions in one repository would be two rows called the same thing.
    func testARowWithoutANameShowsTheDirectoryItIsWorkingIn() {
        let discovered = running(id: 4_242).row(arrivalIndex: 0)
        let unnamedSession = SessionSnapshot(
            id: "claude:abc",
            source: .claude,
            arrivalIndex: 1,
            projectName: "agent-watch",
            lastObservedAt: now
        )

        XCTAssertEqual(rowName(for: discovered, showsSessionTopic: true), "[still no name] in agent-watch")
        XCTAssertEqual(rowName(for: unnamedSession, showsSessionTopic: true), "[still no name] in agent-watch")

        var named = unnamedSession
        named.title = "Slack thread diagnostic"
        XCTAssertEqual(
            rowName(for: named, showsSessionTopic: true),
            "Slack thread diagnostic",
            "a name of its own still wins over the directory"
        )
        XCTAssertNil(
            rowName(for: discovered, showsSessionTopic: false),
            "the setting hides what a row is about, whichever source named it"
        )
    }

    // MARK: - Scaffolding

    private func running(id: Int32) -> DiscoveredAgentProcess {
        DiscoveredAgentProcess(
            source: .claude,
            processID: id,
            startedAt: started,
            projectName: "agent-watch"
        )
    }

    private func makeSupervisor(
        processes: [DiscoveredAgentProcess],
        history: SessionHistoryStore? = nil,
        settings: WidgetSettingsStore? = nil,
        agentProcessStartedAt: @escaping (Int32) -> Date? = { _ in nil }
    ) throws -> SessionSupervisor {
        try makeSupervisor(
            processes: { processes },
            history: history,
            settings: settings,
            agentProcessStartedAt: agentProcessStartedAt
        )
    }

    private func makeSupervisor(
        processes: @escaping () -> [DiscoveredAgentProcess],
        history: SessionHistoryStore? = nil,
        settings: WidgetSettingsStore? = nil,
        agentProcessStartedAt: @escaping (Int32) -> Date? = { _ in nil }
    ) throws -> SessionSupervisor {
        SessionSupervisor(
            settings: try settings ?? WidgetSettingsStore(preferences: isolatedPreferences()),
            // Empty, so no transcript is ever found: these tests are about processes.
            home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            heard: AgentHeardStore(
                directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            history: history
                ?? SessionHistoryStore(
                    directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                ),
            now: { [now] in now },
            liveAgentProcesses: processes,
            agentProcessStartedAt: agentProcessStartedAt,
            onChange: { _, _ in },
            onNotableEvent: { _ in }
        )
    }

    private func makeSettings() throws -> WidgetSettingsStore {
        WidgetSettingsStore(preferences: try isolatedPreferences())
    }

    private func makeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    private func request(event: String, sessionID: String, agentProcessID: Int32) -> HookIngressRequest {
        HookIngressRequest(
            source: .claude,
            declaredEvent: event,
            payload: .object(["session_id": .string(sessionID)]),
            agentProcessID: agentProcessID
        )
    }
}
