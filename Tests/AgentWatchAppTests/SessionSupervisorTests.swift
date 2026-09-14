import AgentWatchCore
import AgentWatchLookup
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The sweep predicate decides whether a repeating timer runs at all, so getting it wrong
/// means either a widget that never tidies itself or a process that wakes forever with
/// nothing to do. It was untestable while it lived inside `AppDelegate`.
@MainActor
final class SessionSupervisorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 4_000)
    /// Moved by hand where a test needs the app to have been away for a while.
    private var clock = Date(timeIntervalSince1970: 4_000)

    func testAWorkingSessionIsWorthSweepingFor() {
        XCTAssertTrue(hasWork(phases: [.executing], retention: .manual))
        XCTAssertTrue(hasWork(phases: [.planning], retention: .manual))
        XCTAssertTrue(hasWork(phases: [.waitingForChildren], retention: .manual))
    }

    func testARestingSessionIsNotWorthWakingUpFor() {
        // The ordinary state between turns. Waking every fifteen seconds for it would be
        // polling with nothing to poll.
        XCTAssertFalse(hasWork(phases: [.completed], retention: .after(120)))
        XCTAssertFalse(hasWork(phases: [.idle], retention: .after(120)))
        XCTAssertFalse(hasWork(phases: [.waitingForUser], retention: .after(120)))
        XCTAssertFalse(hasWork(phases: [.failed], retention: .after(120)))
    }

    func testADisconnectedSessionNeedsNoFurtherSweeping() {
        // Nothing will move it again on its own, which is why its row carries a dismiss button.
        XCTAssertFalse(hasWork(phases: [.disconnected], retention: .after(120)))
    }

    func testAClosedSessionIsSweptOnlyWhileAutomaticRemovalIsOn() {
        XCTAssertTrue(hasWork(phases: [.sessionClosed], retention: .after(120)))
        XCTAssertFalse(hasWork(phases: [.sessionClosed], retention: .manual))
    }

    func testOneWorkingSessionAmongRestingOnesIsEnough() {
        XCTAssertTrue(hasWork(phases: [.completed, .idle, .executing], retention: .manual))
    }

    func testNoSessionsMeansNoSweep() {
        XCTAssertFalse(hasWork(phases: [], retention: .after(120)))
    }

    func testWorkspaceWakeTriggersDiscoveryOnlyUntilSupervisorStops() throws {
        let notifications = NotificationCenter()
        var scans = 0
        let supervisor = try makeSupervisor(
            workspaceNotifications: notifications,
            liveAgentProcesses: {
                scans += 1
                return []
            }
        )
        supervisor.start()
        XCTAssertEqual(scans, 1)
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(scans, 2)
        supervisor.stop()
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(scans, 2, "stopping removes workspace observers")
    }

    // MARK: - What the predicate is wired to

    /// `AGENTS.md`: no polling while there are no active sessions. The predicate above is
    /// only half of that — this is the half that actually starts and stops the timer.
    func testTheSweepTimerRunsOnlyWhileThereIsWork() throws {
        let supervisor = try makeSupervisor()
        XCTAssertFalse(supervisor.isPolling, "a supervisor with no sessions polls nothing")

        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        XCTAssertTrue(supervisor.isPolling, "a working session is worth sweeping for")

        let session = try XCTUnwrap(supervisor.sessions.first)
        supervisor.remove(session)

        XCTAssertFalse(supervisor.isPolling, "the last session left, so the timer has to stop")
    }

    func testAnEventReachesTheSessionsAndIsPublished() throws {
        var published: [[SessionSnapshot]] = []
        let supervisor = try makeSupervisor(onChange: { sessions, _ in published.append(sessions) })

        let event = supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))

        XCTAssertNotNil(event)
        XCTAssertEqual(supervisor.sessions.count, 1)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.count, 1)
    }

    /// The agents view keeps a pre-warmed background session on hand and replaces it the
    /// moment one settles; each replacement sends a start and, seconds later, an end. Such a
    /// session gets no row — and the log says so, because a row that never appeared is
    /// otherwise indistinguishable from an event that never arrived.
    func testABackgroundSessionWithoutATurnGetsNoRowAndIsSaidOutLoud() throws {
        var logged: [String] = []
        var published: [[SessionSnapshot]] = []
        let supervisor = try makeSupervisor(
            onChange: { sessions, _ in published.append(sessions) },
            onNotableEvent: { logged.append($0) })

        let event = supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "spare", clientKind: .background))

        XCTAssertNotNil(event, "the event was understood; it simply has no row of its own yet")
        XCTAssertTrue(supervisor.sessions.isEmpty)
        XCTAssertTrue(published.isEmpty, "nothing changed on the widget, so nothing is published")
        XCTAssertEqual(logged.count, 1)
        let note = try XCTUnwrap(logged.last)
        XCTAssertTrue(note.contains("no row until it takes a turn"), note)
    }

    /// The same session once it does something: the row appears then, with its place at the
    /// end of the list like any newcomer.
    func testABackgroundSessionGetsItsRowOnceItWorks() throws {
        let supervisor = try makeSupervisor()
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "job", clientKind: .background))

        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "job", clientKind: .background))

        XCTAssertEqual(supervisor.sessions.count, 1)
        XCTAssertEqual(supervisor.sessions.first?.phase, .executing)
    }

    /// Fail-open: a request the normalizer cannot make sense of is dropped, not turned into
    /// a session and not reported as a change.
    func testAnUnusableRequestChangesNothing() throws {
        var publishes = 0
        let supervisor = try makeSupervisor(onChange: { _, _ in publishes += 1 })

        let event = supervisor.ingest(testRequest(event: "NotAnEventThisAgentSends", sessionID: "alpha"))

        XCTAssertNil(event)
        XCTAssertTrue(supervisor.sessions.isEmpty)
        XCTAssertEqual(publishes, 0)
    }

    /// The sweep is what removes a closed session once its retention has run out.
    func testTheSweepRetiresAClosedSessionOnceItsTimeIsUp() throws {
        var clock = start
        let supervisor = try makeSupervisor(retention: .after(120), now: { clock })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "SessionEnd", sessionID: "alpha"))
        XCTAssertEqual(supervisor.sessions.first?.phase, .sessionClosed)

        clock = start.addingTimeInterval(60)
        supervisor.runMaintenance()
        XCTAssertEqual(supervisor.sessions.count, 1, "two minutes have not passed")

        clock = start.addingTimeInterval(121)
        supervisor.runMaintenance()

        XCTAssertTrue(supervisor.sessions.isEmpty)
        XCTAssertFalse(supervisor.isPolling, "nothing left to sweep for")
    }

    /// The other half of the sweep, and the one nothing drove at this level. A session nobody
    /// can vouch for is demoted to "no signal" after half an hour; a session some watcher will
    /// report on is left alone however long it is quiet, because a guess is not needed where
    /// there is a real signal coming.
    ///
    /// Both halves in one test on purpose: the rule is which sessions are exempt, and a test
    /// of only the demotion would pass with the exemption removed entirely.
    func testTheSweepDemotesOnlyTheSessionsNoWatcherCanVouchFor() throws {
        var clock = start
        var logged: [String] = []
        let supervisor = try makeSupervisor(now: { clock }, onNotableEvent: { logged.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "unwatched"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "unwatched"))
        // A live process is watched, and its exit will be reported the moment it happens.
        supervisor.ingest(
            testRequest(
                event: "SessionStart",
                sessionID: "watched",
                agentProcessID: ProcessInfo.processInfo.processIdentifier
            )
        )
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "watched"))
        XCTAssertEqual(Set(supervisor.sessions.map(\.phase)), [.executing])

        clock = start.addingTimeInterval(SessionFreshnessEvaluator.defaultDisconnectAfter - 1)
        supervisor.runMaintenance()
        XCTAssertEqual(Set(supervisor.sessions.map(\.phase)), [.executing], "half an hour has not passed")

        logged.removeAll()
        clock = start.addingTimeInterval(SessionFreshnessEvaluator.defaultDisconnectAfter + 1)
        supervisor.runMaintenance()

        // By arrival rather than by name: identifiers are hashed on the way in, and the list
        // keeps the order the sessions appeared in.
        XCTAssertEqual(
            supervisor.sessions.map(\.phase),
            [.disconnected, .executing],
            "a live process-exit watch is a better answer than a timeout, so only the first is demoted"
        )
        XCTAssertEqual(logged.count, 1, "the demotion is said out loud, once")
        // Two sessions and one line: saying that a session was demoted is only half an
        // answer while the log does not say which.
        let line = try XCTUnwrap(logged.last)
        let demoted = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertTrue(line.contains(demoted.id), line)
    }

    /// An app whose job is to notice things was silently dropping every event it could not
    /// understand — no line, no counter, nothing anywhere. That is the one class of failure
    /// a monitor is not allowed to have, and it is also why an open question about the event
    /// log could not be answered: there was no way to tell "the event arrived and was
    /// refused" from "the event never arrived".
    func testAnEventThisAppCannotUnderstandIsSaidOutLoudRatherThanDropped() throws {
        var logged: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { logged.append($0) })

        // Refused by the redactor's allowlist, before anything is parsed.
        supervisor.ingest(testRequest(event: "SomethingNobodyRegistered", sessionID: "alpha"))
        XCTAssertTrue(supervisor.sessions.isEmpty, "an event that was refused starts no session")
        XCTAssertEqual(logged.count, 1)
        let refusal = try XCTUnwrap(logged.last)
        XCTAssertTrue(refusal.contains("hook name this app does not handle"), refusal)

        // The other refusal a real hook can produce: a tool event with no call named in it.
        // This is the shape the open question about orphaned completions turns on.
        supervisor.ingest(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "PreToolUse",
                payload: .object(["session_id": .string("alpha")])
            )
        )
        XCTAssertEqual(logged.count, 2)
        XCTAssertNotEqual(logged.last, logged.first, "which refusal it was decides what to do about it")
    }

    // MARK: - Where the two sources meet

    /// The case the transcript exists for: a call the hooks opened and never closed. The
    /// widget counted it through every following turn until some later `Stop` swept it.
    func testTheTranscriptClosesACallTheHooksLeftOpen() throws {
        var logged: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { logged.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        supervisor.ingest(toolCall(sessionID: "alpha", toolUseID: "tool-1"))
        let session = try XCTUnwrap(supervisor.sessions.first)
        let activityID = try XCTUnwrap(session.activities.first?.id)

        supervisor.applyTranscript([
            TranscriptUpdate(
                sessionID: session.id,
                facts: [.callReturned(activityID: activityID, at: start + 5)],
                fault: nil
            )
        ])

        XCTAssertTrue(supervisor.sessions.first?.activities.isEmpty == true)
        // What matters is that the transcript's contribution is announced and attributed to
        // the agent it came from. Pinning the sentence itself would fail on a rewording that
        // changes no behaviour, and pass on a line attributed to the wrong agent.
        XCTAssertEqual(logged.count, 1)
        let line = try XCTUnwrap(logged.last)
        XCTAssertTrue(line.hasPrefix("Claude · "), line)
        XCTAssertTrue(line.contains("· transcript ·"), line)
    }

    /// A hook line names its session; these did not. That is the difference between a log
    /// that answers "which of the two sessions went quiet" and one that only says "one did".
    func testATranscriptLineNamesTheSessionItBelongsTo() throws {
        var logged: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { logged.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        supervisor.ingest(toolCall(sessionID: "alpha", toolUseID: "tool-1"))
        let session = try XCTUnwrap(supervisor.sessions.first)
        let activityID = try XCTUnwrap(session.activities.first?.id)

        supervisor.applyTranscript([
            TranscriptUpdate(
                sessionID: session.id,
                facts: [.callReturned(activityID: activityID, at: start + 5)],
                fault: nil
            )
        ])

        let line = try XCTUnwrap(logged.last)
        XCTAssertTrue(line.contains(session.id), "\(line) does not say which session it is about")
    }

    /// The transcript's half of the refusal above. A hook this app could not apply says so;
    /// a transcript fact it could not apply used to vanish without a trace, so a missing
    /// ending could not be told apart from an ending that arrived and was thrown away.
    func testATranscriptFactForASessionThisAppDoesNotHaveIsSaidOutLoud() throws {
        var logged: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { logged.append($0) })

        supervisor.applyTranscript([
            TranscriptUpdate(
                sessionID: "id_nobody",
                facts: [.callReturned(activityID: "id_call", at: start + 5)],
                fault: nil
            )
        ])

        XCTAssertEqual(logged.count, 1)
        let line = try XCTUnwrap(logged.last)
        XCTAssertTrue(line.contains("id_nobody"), "\(line) does not say which session it is about")
        XCTAssertTrue(line.contains("· transcript ·"), line)
        XCTAssertTrue(line.contains("refused"), "\(line) does not say the fact was thrown away")
    }

    /// Both sources nearly always agree. Logging the agreements would bury the handful of
    /// lines this log exists to produce.
    func testAnEndingBothSourcesReportIsNotLoggedTwice() throws {
        var logged: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { logged.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        let session = try XCTUnwrap(supervisor.sessions.first)

        supervisor.applyTranscript([
            TranscriptUpdate(
                sessionID: session.id,
                facts: [.callReturned(activityID: "a-call-nobody-opened", at: start + 5)],
                fault: nil
            )
        ])

        XCTAssertTrue(logged.isEmpty)
    }

    /// Growth and an interruption arrive in the same read, and the interruption is older than
    /// the newest line beside it — the agent writes on for a moment before it stops. The
    /// order decides whether the turn ends at all: move the age first and the interruption is
    /// judged stale by the very lines it arrived with.
    func testAnInterruptionIsNotOutrankedByTheLinesItArrivedWith() throws {
        let supervisor = try makeSupervisor()
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        let session = try XCTUnwrap(supervisor.sessions.first)

        supervisor.applyTranscript([
            TranscriptUpdate(
                sessionID: session.id,
                facts: [.turnInterrupted(at: start + 5)],
                fault: nil,
                newestRecordAt: start + 9
            )
        ])

        XCTAssertEqual(supervisor.sessions.first?.phase, .idle)
        XCTAssertEqual(supervisor.sessions.first?.lastObservedAt, start + 9)
    }

    func testAFaultIsCarriedOntoTheSessionAndSaidOutLoudOnce() throws {
        var logged: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { logged.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        let session = try XCTUnwrap(supervisor.sessions.first)
        let faulted = TranscriptUpdate(sessionID: session.id, facts: [], fault: .transcriptNotFound)

        supervisor.applyTranscript([faulted])
        supervisor.applyTranscript([faulted])

        XCTAssertEqual(supervisor.sessions.first?.monitoringFault, .transcriptNotFound)
        XCTAssertEqual(supervisor.faultedSessionCount, 1)
        XCTAssertEqual(logged.count, 1, "a fault that has not changed is not news")
        let raised = try XCTUnwrap(logged.last)
        XCTAssertTrue(raised.hasPrefix("Claude · "))

        supervisor.applyTranscript([TranscriptUpdate(sessionID: session.id, facts: [], fault: nil)])
        XCTAssertNil(supervisor.sessions.first?.monitoringFault)
        XCTAssertEqual(logged.count, 2, "recovery is news too")
        XCTAssertNotEqual(logged.last, raised, "and it does not read like the fault it ended")
    }

    /// The same for a fault, and this is the line where it matters most: "unexplained
    /// silence" with no session named is an entry nobody can act on.
    func testAFaultLineNamesTheSessionItBelongsTo() throws {
        var logged: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { logged.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        let session = try XCTUnwrap(supervisor.sessions.first)

        supervisor.applyTranscript([
            TranscriptUpdate(sessionID: session.id, facts: [], fault: .transcriptNotFound)
        ])
        let raised = try XCTUnwrap(logged.last)
        XCTAssertTrue(raised.contains(session.id), raised)

        supervisor.applyTranscript([TranscriptUpdate(sessionID: session.id, facts: [], fault: nil)])
        let recovered = try XCTUnwrap(logged.last)
        XCTAssertTrue(recovered.contains(session.id), recovered)
    }

    /// The reader can only pull a read towards a hook if it is told a hook arrived. Without
    /// that one line the schedule would still be a metronome, and every other test would pass.
    ///
    /// The moment is exact on purpose: untold, the reader would still be holding the read at
    /// the floor five seconds after the previous hook, not half a second after this one.
    func testAHookMovesTheReadToJustAfterItself() throws {
        var clock = start
        let supervisor = try makeSupervisor(now: { clock })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha"))
        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha"))
        XCTAssertEqual(supervisor.nextTranscriptReadAt, start.addingTimeInterval(5))

        clock = start.addingTimeInterval(6)
        supervisor.ingest(toolCall(sessionID: "alpha", toolUseID: "tool-1"))

        XCTAssertEqual(
            supervisor.nextTranscriptReadAt,
            clock.addingTimeInterval(TranscriptWatcher.coalesceWindow)
        )
    }

    // MARK: - Helpers

    /// The proof an installation works cannot come from the configuration on disk — it says
    /// what an agent is asked for, not what it does. It comes from an event arriving, and
    /// **any** event counts: one this app could not understand still crossed the socket, which
    /// is the whole fact being remembered. Refusing to remember it would leave a person told
    /// their hooks have never delivered while the log beside it lists the refusals.
    func testEvenAnEventThisAppCannotUnderstandProvesTheAgentCanReach() throws {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let heard = AgentHeardStore(directoryURL: directory)
        let supervisor = try makeSupervisor(heard: heard)

        // No `session_id`, so normalization refuses it — the app learns nothing about any
        // session, and everything about the agent being able to reach it.
        let refused = supervisor.ingest(
            HookIngressRequest(source: .codex, declaredEvent: "SessionStart", payload: .object([:]))
        )

        XCTAssertNil(refused, "the event has to be one the app really cannot use")
        XCTAssertEqual(heard.delivery(for: .codex), .arrived)
        XCTAssertEqual(heard.delivery(for: .claude), .unknown, "and it says nothing about the other agent")
    }

    // MARK: - Across a restart

    /// The gap this closes: the app learns of a session only from a hook, so after a restart
    /// the widget stayed empty until every session happened to do something next.
    ///
    /// The host here is the test process itself — a real PID, started before the session's own
    /// events — which is exactly what the restore rule asks for evidence of.
    func testASessionSurvivesARestartAndItsNextHookLandsOnTheSameRow() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()

        let firstLaunch = try makeSupervisor(
            now: { Date() },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: getpid()))
        firstLaunch.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha", agentProcessID: getpid()))
        let working = try XCTUnwrap(firstLaunch.sessions.first)
        XCTAssertTrue(working.phase.claimsWork)
        firstLaunch.stop()

        var published: [[SessionSnapshot]] = []
        let secondLaunch = try makeSupervisor(
            now: { Date() },
            onChange: { sessions, _ in published.append(sessions) },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        XCTAssertEqual(secondLaunch.sessions.map(\.id), [working.id])
        XCTAssertEqual(secondLaunch.sessions.first?.phase, .disconnected)
        XCTAssertEqual(secondLaunch.sessions.first?.arrivalIndex, working.arrivalIndex)
        XCTAssertEqual(published.count, 1, "a restored session is a change the widget has to be told about")

        secondLaunch.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha", agentProcessID: getpid()))

        XCTAssertEqual(secondLaunch.sessions.count, 1, "the hook lands on the row that came back")
        XCTAssertTrue(try XCTUnwrap(secondLaunch.sessions.first).phase.claimsWork)
    }

    /// A session whose agent is gone stays gone. Its PID belongs to nobody — or, after a
    /// laptop ran long enough for the numbers to wrap around, to something else entirely.
    func testASessionWhoseHostIsGoneIsNotBroughtBack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()

        let firstLaunch = try makeSupervisor(
            now: { Date() },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        // A PID above the system maximum belongs to nobody and never will.
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: 999_999))
        firstLaunch.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha", agentProcessID: 999_999))
        XCTAssertEqual(firstLaunch.sessions.count, 1)
        firstLaunch.stop()

        let secondLaunch = try makeSupervisor(
            now: { Date() },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        XCTAssertEqual(secondLaunch.sessions, [])
        XCTAssertEqual(
            SessionHistoryStore(directoryURL: directory).remembered,
            [],
            "and the memory is given up, so the next launch does not ask about it again"
        )
    }

    /// The other half of what a restart owes the reader: not just the row, but an honest age
    /// on it. A restored session is `disconnected`, so the timer never reads it, and without
    /// this it would show the age the memory happened to hold — the write window plus however
    /// long the app was down — in orange, under "no signal".
    func testARestoredSessionTakesItsAgeFromItsOwnTranscript() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        // A real Claude session identifier, because the file is found by hashing its name.
        let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
        let home = try makeTranscript(named: sessionUUID, in: directory)
        let sessionID = try senderSideSessionID(sessionUUID)

        clock = Date()
        let firstLaunch = try makeSupervisor(
            now: { self.clock },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.stop()

        // The session went on working while the app was not running, and its transcript is the
        // only record of that anywhere.
        let grewAt = clock + 60
        try FileManager.default.setAttributes(
            [.modificationDate: grewAt],
            ofItemAtPath: home.appendingPathComponent(".claude/projects/p/\(sessionUUID).jsonl").path
        )
        clock = clock + 120

        let republished = expectation(description: "the catch-up reported back")
        let secondLaunch = try makeSupervisor(
            now: { self.clock },
            onChange: { sessions, _ in
                if sessions.first?.lastObservedAt == grewAt {
                    republished.fulfill()
                }
            },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        await fulfillment(of: [republished], timeout: 2)
        XCTAssertEqual(secondLaunch.sessions.first?.lastObservedAt, grewAt)
        XCTAssertEqual(
            secondLaunch.sessions.first?.phase,
            .disconnected,
            "reading the file says when, never what: the phase still waits for a hook"
        )
    }

    /// The third thing a restart owes the reader: the name the session answers to now.
    ///
    /// A session renames itself as its work moves on, and the memory holds whatever it was
    /// called when the app last ran. The file is the fresher of the two, and it is the one
    /// place the name can be had while no hook is arriving.
    func testARestoredSessionTakesItsCurrentNameFromItsOwnTranscript() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
        let home = try makeTranscript(named: sessionUUID, in: directory)
        let sessionID = try senderSideSessionID(sessionUUID)

        clock = Date()
        let firstLaunch = try makeSupervisor(
            now: { self.clock },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        firstLaunch.ingest(
            testRequest(
                event: "SessionStart",
                sessionID: sessionID,
                agentProcessID: getpid(),
                description: SessionDescription(title: "what it used to be about")
            )
        )
        XCTAssertEqual(firstLaunch.sessions.first?.title, "what it used to be about")
        firstLaunch.stop()

        // The session went on working, and renamed itself, while the app was not running.
        try Data(
            """
            {"type":"ai-title","aiTitle":"what it is about now","sessionId":"\(sessionUUID)"}

            """.utf8
        )
        .write(to: home.appendingPathComponent(".claude/projects/p/\(sessionUUID).jsonl"))

        let renamed = expectation(description: "the catch-up reported the new name")
        let secondLaunch = try makeSupervisor(
            now: { self.clock },
            onChange: { sessions, _ in
                if sessions.first?.title == "what it is about now" {
                    renamed.fulfill()
                }
            },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        await fulfillment(of: [renamed], timeout: 2)
        XCTAssertEqual(
            secondLaunch.sessions.first?.phase,
            .disconnected,
            "a name is not a lifecycle fact: the phase still waits for a hook"
        )
    }

    /// The case a person hit: a row dismissed by hand, an agent that never stopped running,
    /// and a name that was in the transcript the whole time and could not be reached.
    ///
    /// Dismissing takes the session out of the file, so the next launch finds the agent by
    /// its process alone. What brings the name back is the pairing the first hook stated —
    /// this process is that session — which is kept apart from the session it names.
    func testAnAgentRediscoveredAfterItsRowWasDismissedIsStillItsSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
        let home = try makeTranscript(named: sessionUUID, in: directory)
        let sessionID = try senderSideSessionID(sessionUUID)
        let startedAt = Date(timeIntervalSince1970: 3_000)
        // This test's own process, because the row gets a process-exit watch: a made-up
        // number is a process that has already exited, and the row would be taken away
        // again before the transcript could be read.
        let agentProcessID = ProcessInfo.processInfo.processIdentifier
        let running = DiscoveredAgentProcess(
            source: .claude,
            processID: agentProcessID,
            startedAt: startedAt,
            projectName: "sample-cli"
        )

        let firstLaunch = try makeSupervisor(
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home,
            liveAgentProcesses: { [running] },
            agentProcessStartedAt: { _ in startedAt }
        )
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: sessionID, agentProcessID: agentProcessID))
        let session = try XCTUnwrap(firstLaunch.sessions.first)
        firstLaunch.remove(session)
        XCTAssertEqual(firstLaunch.sessions, [], "the row is gone, and so is its record")
        firstLaunch.stop()

        // The session goes on working, and names itself, while the app is not running.
        try Data(
            """
            {"type":"ai-title","aiTitle":"what it is about now","sessionId":"\(sessionUUID)"}

            """.utf8
        )
        .write(to: home.appendingPathComponent(".claude/projects/p/\(sessionUUID).jsonl"))

        let named = expectation(description: "the rediscovered agent was named from its own transcript")
        let secondLaunch = try makeSupervisor(
            onChange: { sessions, _ in
                if sessions.first?.title == "what it is about now" {
                    named.fulfill()
                }
            },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home,
            liveAgentProcesses: { [running] },
            agentProcessStartedAt: { _ in startedAt }
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        await fulfillment(of: [named], timeout: 2)
        XCTAssertEqual(
            secondLaunch.sessions.map(\.id),
            [session.id],
            "the row is the session, not a row about the process it runs in"
        )
    }

    /// A catch-up can be declined — the reader takes one read at a time, and at launch the
    /// restored sessions are already being read when the scan runs. Nothing else would ask
    /// again: a row whose silence is expected gets no scheduled reads. So every scan offers
    /// every recognised row, and not only the ones it has just added.
    ///
    /// The refusal here is the reader being switched off, which is the one that can be
    /// arranged exactly; the effect on the row is the same either way.
    func testARecognisedRowGetsAnotherChanceAtItsTranscript() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
        let home = try makeTranscript(named: sessionUUID, in: directory)
        let sessionID = try senderSideSessionID(sessionUUID)
        let startedAt = Date(timeIntervalSince1970: 3_000)
        let agentProcessID = ProcessInfo.processInfo.processIdentifier
        let running = DiscoveredAgentProcess(
            source: .claude,
            processID: agentProcessID,
            startedAt: startedAt,
            projectName: "sample-cli"
        )

        let firstLaunch = try makeSupervisor(
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home,
            liveAgentProcesses: { [running] },
            agentProcessStartedAt: { _ in startedAt }
        )
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: sessionID, agentProcessID: agentProcessID))
        firstLaunch.remove(try XCTUnwrap(firstLaunch.sessions.first))
        firstLaunch.stop()
        try Data(
            """
            {"type":"ai-title","aiTitle":"what it is about now","sessionId":"\(sessionUUID)"}

            """.utf8
        )
        .write(to: home.appendingPathComponent(".claude/projects/p/\(sessionUUID).jsonl"))

        // The reader is off, so the launch recognises the row and reads nothing.
        settings.setTranscriptPollInterval(nil)
        let named = expectation(description: "the second scan got the name the first could not")
        let secondLaunch = try makeSupervisor(
            onChange: { sessions, _ in
                if sessions.first?.title == "what it is about now" {
                    named.fulfill()
                }
            },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home,
            liveAgentProcesses: { [running] },
            agentProcessStartedAt: { _ in startedAt }
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }
        XCTAssertNil(secondLaunch.sessions.first?.title, "nothing was read, so nothing is claimed")

        settings.setTranscriptPollInterval(5)
        // A scan that adds no row at all: the same process, already on the widget.
        secondLaunch.discoverAgentProcesses()

        await fulfillment(of: [named], timeout: 2)
    }

    /// The whole of the second half of a restart, through the application: the file kept the
    /// wait, the reader asked the transcript about it, and only then did the row say so.
    ///
    /// The transcript here holds one record with no timestamp and no call in it, which is the
    /// shape of a session that has done nothing since — so the wait stands.
    func testARememberedWaitComesBackOnceTheTranscriptAgrees() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
        let home = try makeTranscript(named: sessionUUID, in: directory)
        let sessionID = try senderSideSessionID(sessionUUID)

        clock = Date()
        let firstLaunch = try makeSupervisor(
            now: { self.clock },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.ingest(testRequest(event: "UserPromptSubmit", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.ingest(toolCall(sessionID: sessionID, toolUseID: try senderSideToolUseID("toolu_01")))
        firstLaunch.ingest(testRequest(event: "PermissionRequest", sessionID: sessionID, agentProcessID: getpid()))
        XCTAssertEqual(firstLaunch.sessions.first?.phase, .waitingForUser)
        let awaited = try XCTUnwrap(firstLaunch.sessions.first?.awaitedActivityID)
        firstLaunch.stop()

        let waitingAgain = expectation(description: "the catch-up put the wait back")
        let secondLaunch = try makeSupervisor(
            now: { self.clock },
            onChange: { sessions, _ in
                if sessions.first?.phase == .waitingForUser {
                    waitingAgain.fulfill()
                }
            },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }

        XCTAssertEqual(
            secondLaunch.sessions.first?.phase,
            .disconnected,
            "the row claims nothing until its own file has answered"
        )

        await fulfillment(of: [waitingAgain], timeout: 2)
        XCTAssertEqual(secondLaunch.sessions.first?.userInputRequestKind, .approval)
        XCTAssertEqual(secondLaunch.sessions.first?.awaitedActivityID, awaited)
    }

    /// Quitting before the transcript has answered must not lose the wait.
    ///
    /// Restoring publishes straight away — that write is what drops the sessions whose agents
    /// are gone — and at that moment the row has already been demoted to `no signal` while
    /// the wait lives in the engine's memory alone. A file written from the demoted row would
    /// mean the launch that exists to bring the wait back is the one that erased it, and a
    /// quit inside that window would lose it for good.
    ///
    /// Read straight after `start()` on purpose: the catch-up reads on a detached task and
    /// reports back on the main actor, which this test still holds, so this is the window.
    func testQuittingBeforeTheTranscriptAnswersKeepsTheWaitInTheFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
        let home = try makeTranscript(named: sessionUUID, in: directory)
        let sessionID = try senderSideSessionID(sessionUUID)

        clock = Date()
        let firstLaunch = try makeSupervisor(
            now: { self.clock },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.ingest(testRequest(event: "UserPromptSubmit", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.ingest(toolCall(sessionID: sessionID, toolUseID: try senderSideToolUseID("toolu_01")))
        firstLaunch.ingest(testRequest(event: "PermissionRequest", sessionID: sessionID, agentProcessID: getpid()))
        let awaited = try XCTUnwrap(firstLaunch.sessions.first?.awaitedActivityID)
        firstLaunch.stop()

        let secondLaunch = try makeSupervisor(
            now: { self.clock },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        secondLaunch.start()
        secondLaunch.stop()

        let onDisk = try XCTUnwrap(SessionHistoryStore(directoryURL: directory).remembered.first)
        XCTAssertEqual(onDisk.phase, .waitingForUser, "the file goes on saying what it said")
        XCTAssertEqual(onDisk.awaitedActivityID, awaited)
    }

    /// The other direction, and the one that costs something to get wrong: the person
    /// answered while the app was down, so the call reported back and the wait is over.
    func testAWaitTheTranscriptHasAnsweredDoesNotComeBack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
        let home = try makeTranscript(named: sessionUUID, in: directory)
        let sessionID = try senderSideSessionID(sessionUUID)

        clock = Date()
        let firstLaunch = try makeSupervisor(
            now: { self.clock },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        firstLaunch.ingest(testRequest(event: "SessionStart", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.ingest(testRequest(event: "UserPromptSubmit", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.ingest(toolCall(sessionID: sessionID, toolUseID: try senderSideToolUseID("toolu_01")))
        firstLaunch.ingest(testRequest(event: "PermissionRequest", sessionID: sessionID, agentProcessID: getpid()))
        firstLaunch.stop()

        // The call the session was waiting on reported back a minute later, which the
        // transcript records and nothing else does. The identifier is the raw one the agent
        // writes: the reader hashes it into the same label the socket path produced, which is
        // the whole reason the two sources can be talked about together.
        try appendToolResult(
            toolUseID: "toolu_01",
            at: clock + 60,
            toTranscriptNamed: sessionUUID,
            in: home
        )

        let caughtUp = expectation(description: "the catch-up reported back")
        let secondLaunch = try makeSupervisor(
            now: { self.clock },
            onChange: { sessions, _ in
                if sessions.first?.lastObservedAt != nil, sessions.first?.title == nil {
                    caughtUp.fulfill()
                }
            },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home
        )
        secondLaunch.start()
        defer { secondLaunch.stop() }
        await fulfillment(of: [caughtUp], timeout: 2)

        XCTAssertEqual(
            secondLaunch.sessions.first?.phase,
            .disconnected,
            "the wait is over, and the row says only that nothing has been heard"
        )
    }

    /// A tool call identifier as the sender puts it on the socket. The app hashes whatever
    /// arrives a second time, so this is what makes a test's identifier end up as the same
    /// label the transcript reader derives from the raw one.
    private func senderSideToolUseID(_ rawToolUseID: String) throws -> String {
        let onTheSocket = try HookCaptureRedactor.redact(
            declaredEvent: "PreToolUse",
            payload: .object(["tool_use_id": .string(rawToolUseID)])
        )
        guard case let .object(fields) = onTheSocket.payload, case let .string(value)? = fields["tool_use_id"] else {
            XCTFail("the redactor no longer carries a tool call identifier")
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    /// A Claude `tool_result` record, in the shape the reader recognises.
    private func appendToolResult(
        toolUseID: String,
        at moment: Date,
        toTranscriptNamed sessionUUID: String,
        in home: URL
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let record = """
            {"type":"user","timestamp":"\(formatter.string(from: moment))","message":{"role":"user","content":\
            [{"type":"tool_result","tool_use_id":"\(toolUseID)"}]}}
            """
        let url = home.appendingPathComponent(".claude/projects/p/\(sessionUUID).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((record.replacingOccurrences(of: "\\\n", with: "") + "\n").utf8))
    }

    /// The session identifier as a sender would put it on the socket: hashed once there, and
    /// once more by the app, which is exactly what makes it equal to the label a transcript's
    /// own file name hashes to. Passing the raw identifier instead lands on a label no
    /// transcript can ever produce, and the symptom is a reader that silently finds nothing.
    private func senderSideSessionID(_ rawSessionUUID: String) throws -> String {
        let onTheSocket = try HookCaptureRedactor.redact(
            declaredEvent: "SessionStart",
            payload: .object(["session_id": .string(rawSessionUUID)])
        )
        guard case let .object(fields) = onTheSocket.payload, case let .string(value)? = fields["session_id"] else {
            XCTFail("the redactor no longer carries a session identifier")
            throw CocoaError(.coderInvalidValue)
        }
        return value
    }

    /// A home with one Claude transcript in it, named the way Claude names them.
    private func makeTranscript(named sessionUUID: String, in directory: URL) throws -> URL {
        let projects = directory.appendingPathComponent(".claude/projects/p", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n".utf8)
            .write(to: projects.appendingPathComponent("\(sessionUUID).jsonl"))
        return directory
    }

    /// A hook from a copy of `original`, as the sender names it: the original in every event.
    private func copyRequest(
        event: String, sessionID: String, of original: String, agentProcessID: Int32
    ) -> HookIngressRequest {
        HookIngressRequest(
            source: .claude,
            declaredEvent: event,
            payload: .object([
                "session_id": .string(sessionID), "forked_from_session_id": .string(original),
            ]),
            agentProcessID: agentProcessID,
            clientKind: .background
        )
    }

    /// Claude Code's own records of its processes, `~/.claude/sessions/<pid>.json`, under a
    /// home of the test's own.
    private func writeSessionRecords(in home: URL, _ records: [Int32: String]) throws {
        let sessions =
            home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for (processID, record) in records {
            try Data(record.utf8).write(to: sessions.appendingPathComponent("\(processID).json"))
        }
    }

    /// The number of a process that has already exited: a child run to completion.
    private func exitedProcessID() throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        return child.processIdentifier
    }

    private func makeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    // MARK: - A process that moved on to another session

    /// The whole path `/resume` takes through the app: `claude` starts a session of its own,
    /// ends it two seconds later when the conversation is resumed, and the resumed session
    /// starts in the same process. Only the resumed one is a row.
    func testResumingLeavesNoRowForTheSessionItReplaced() throws {
        var notable: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { notable.append($0) })

        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "throwaway", agentProcessID: 501))
        supervisor.ingest(testRequest(event: "SessionEnd", sessionID: "throwaway", agentProcessID: 501))
        let resumed = supervisor.ingest(testRequest(event: "SessionStart", sessionID: "resumed", agentProcessID: 501))

        // Asked of the event rather than written out: the identifier a session is filed
        // under is its own put through the redaction.
        let resumedID = SessionSnapshot.id(source: .claude, sessionLabel: try XCTUnwrap(resumed).sessionID)
        XCTAssertEqual(supervisor.sessions.map(\.id), [resumedID])
        XCTAssertTrue(
            notable.contains { $0.contains("closed session dropped") },
            "a row that leaves has to be in the log; \(notable)"
        )
    }

    /// `/bg` continues a session in a copy under a new identifier. Its hooks arrive naming the
    /// original, and the whole path — redaction on arrival, the engine, the process pairing —
    /// has to agree that they are the original's row: one row, now on the copy's process, and
    /// one line in the log saying so, since a row that silently changes its process and its
    /// kind of place is a row a person cannot check against.
    func testASessionSentToTheBackgroundKeepsItsRow() throws {
        var log: [String] = []
        let supervisor = try makeSupervisor(
            onNotableEvent: { log.append($0) },
            agentProcessStartedAt: { _ in Date(timeIntervalSince1970: 3_900) }
        )
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: 501))
        let copy = HookIngressRequest(
            source: .claude,
            declaredEvent: "SessionStart",
            payload: .object([
                "session_id": .string("beta"),
                "forked_from_session_id": .string("alpha"),
                "source": .string("fork"),
            ]),
            agentProcessID: 502,
            clientKind: .background
        )

        supervisor.ingest(copy)
        supervisor.ingest(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "UserPromptSubmit",
                payload: .object(["session_id": .string("beta"), "forked_from_session_id": .string("alpha")]),
                agentProcessID: 502,
                clientKind: .background
            )
        )

        XCTAssertEqual(supervisor.sessions.count, 1, "one conversation, one row")
        let row = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(row.agentProcessID, 502)
        XCTAssertEqual(row.clientKind, .background)
        XCTAssertEqual(row.phase, .executing, "the copy's turn is the row's turn")
        XCTAssertEqual(
            log.filter { $0.contains("continued") }.count,
            1,
            "said once, when the copy joins — not on every event it sends afterwards: \(log)"
        )
    }

    /// The launch that brings this rule in finds the file of the launch before it: a row for
    /// the original and a row for the copy, remembered as two sessions. The copy's next hook
    /// names the original, and the two rows become one — the original's, now on the copy's
    /// process — with the copy's own row gone, its watcher with it, and one line saying so.
    func testTwoRowsRememberedForOneConversationBecomeOneOnTheCopysNextHook() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let original = getpid()
        let copy = getppid()

        let before = try makeSupervisor(
            now: { Date() },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        before.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: original))
        // What the old sender said about the copy: a session of its own, nothing about alpha.
        before.ingest(testRequest(event: "SessionStart", sessionID: "beta", agentProcessID: copy))
        XCTAssertEqual(before.sessions.count, 2)
        before.stop()

        var log: [String] = []
        let after = try makeSupervisor(
            now: { Date() },
            onNotableEvent: { log.append($0) },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings
        )
        after.start()
        defer { after.stop() }
        XCTAssertEqual(after.sessions.count, 2, "the file of the old launch is taken as it is")

        after.ingest(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "UserPromptSubmit",
                payload: .object(["session_id": .string("beta"), "forked_from_session_id": .string("alpha")]),
                agentProcessID: copy,
                clientKind: .background
            )
        )

        let rows = after.sessions
        XCTAssertEqual(rows.count, 1, "one conversation, one row: \(rows.map(\.id))")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, try XCTUnwrap(before.sessions.first { $0.agentProcessID == original }).id)
        XCTAssertEqual(row.agentProcessID, copy)
        XCTAssertEqual(row.clientKind, .background)
        XCTAssertTrue(row.phase.claimsWork, "the copy's turn is the row's turn")
        XCTAssertEqual(log.filter { $0.contains("continued") }.count, 1, "\(log)")
    }

    /// `/bg` leaves the terminal it was typed in showing the session: the interactive process
    /// stays alive and Claude Code's record of it names the job as parked. Measured on 2.1.269
    /// — the terminal that parked the job was the only interactive process attached to the
    /// daemon, and no `claude attach` ran anywhere. That terminal is where a person finds the
    /// session, so the row is reached through it, and the log says so once.
    func testTheTerminalThatSentTheSessionToTheBackgroundIsWhereTheRowIsReached() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSessionRecords(
            in: home,
            [
                501: #"{"pid":501,"kind":"interactive","name":"agent-watch-31","parkedJobId":"job1"}"#,
                502: #"{"pid":502,"kind":"bg","jobId":"job1"}"#,
            ])
        var log: [String] = []
        let supervisor = try makeSupervisor(
            onNotableEvent: { log.append($0) },
            home: home,
            agentProcessStartedAt: { _ in Date(timeIntervalSince1970: 3_900) }
        )
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: 501))

        supervisor.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: 502))
        supervisor.ingest(copyRequest(event: "UserPromptSubmit", sessionID: "beta", of: "alpha", agentProcessID: 502))

        let row = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(supervisor.sessions.count, 1)
        XCTAssertEqual(row.viewerProcessID, 501, "the terminal that parked the job shows it")
        XCTAssertEqual(row.hostKind, .cli)
        XCTAssertEqual(row.agentProcessID, 502)
        XCTAssertEqual(
            log.filter { $0.contains("on screen in the terminal that sent it to the background") }.count, 1, "\(log)")
    }

    /// The copy's process first runs the two-second session `--resume` always leaves behind,
    /// and that stub's hooks come first: a background session that names no original, starts,
    /// and ends. It gets no row at all — a background session with nothing to show for itself
    /// waits (`SessionStateEngine.withholdsRow`) — and so it claims no terminal either. The
    /// copy's own start claims it once.
    func testTheStubTheCopysProcessRunsFirstNeitherGetsARowNorClaimsTheTerminal() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSessionRecords(
            in: home,
            [
                501: #"{"pid":501,"kind":"interactive","parkedJobId":"job1"}"#,
                502: #"{"pid":502,"kind":"bg","jobId":"job1"}"#,
            ])
        var log: [String] = []
        let supervisor = try makeSupervisor(
            onNotableEvent: { log.append($0) },
            home: home,
            agentProcessStartedAt: { _ in Date(timeIntervalSince1970: 3_900) }
        )
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: 501))
        let original = try XCTUnwrap(supervisor.sessions.first)

        let stubRequest = { (event: String) in
            HookIngressRequest(
                source: .claude, declaredEvent: event, payload: .object(["session_id": .string("stub")]),
                agentProcessID: 502, clientKind: .background)
        }
        supervisor.ingest(stubRequest("SessionStart"))
        XCTAssertEqual(supervisor.sessions.map(\.id), [original.id], "the stub is nobody's row")
        XCTAssertTrue(log.allSatisfy { !$0.contains("on screen in the terminal") }, "\(log)")
        supervisor.ingest(stubRequest("SessionEnd"))

        supervisor.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: 502))

        XCTAssertEqual(supervisor.sessions.map(\.id), [original.id], "the copy joins the row it continues")
        XCTAssertEqual(supervisor.sessions.first?.viewerProcessID, 501)
        XCTAssertEqual(
            log.filter { $0.contains("on screen in the terminal that sent it to the background") }.count, 1, "\(log)")
    }

    /// After `/bg` a person can go back to the original in the same terminal and keep working
    /// there: the original speaks for itself, the copy is a row of its own — and the terminal
    /// now runs the original, whatever its record still says about the parked job (whether
    /// Claude Code clears `parkedJobId` then is not measured). A process that runs another
    /// row's conversation is nobody's viewer: the copy's row is a background one, with its door.
    func testATerminalRunningAnotherRowIsNobodysViewer() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSessionRecords(
            in: home,
            [
                501: #"{"pid":501,"kind":"interactive","parkedJobId":"job1"}"#,
                502: #"{"pid":502,"kind":"bg","jobId":"job1"}"#,
            ])
        var log: [String] = []
        let supervisor = try makeSupervisor(
            onNotableEvent: { log.append($0) },
            home: home,
            agentProcessStartedAt: { _ in Date(timeIntervalSince1970: 3_900) }
        )
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: 501))
        supervisor.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: 502))
        XCTAssertEqual(supervisor.sessions.first?.viewerProcessID, 501)

        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha", agentProcessID: 501))
        supervisor.ingest(copyRequest(event: "UserPromptSubmit", sessionID: "beta", of: "alpha", agentProcessID: 502))

        XCTAssertEqual(supervisor.sessions.count, 2, "two live sessions, two rows: \(supervisor.sessions.map(\.id))")
        let copy = try XCTUnwrap(supervisor.sessions.first { $0.agentProcessID == 502 })
        XCTAssertNil(copy.viewerProcessID, "the terminal runs the original now")
        XCTAssertEqual(copy.hostKind, .background)
        XCTAssertEqual(
            log.filter { $0.contains("on screen in the terminal that sent it to the background") }.count, 1, "\(log)")
    }

    /// The terminal closing does not end the session — it runs on in its own process — but it
    /// does take the window away. The row is a background one again from that moment, and the
    /// log says what a click does now.
    func testTheTerminalClosingMakesTheRowABackgroundOneAgain() throws {
        let terminal = Process()
        terminal.executableURL = URL(fileURLWithPath: "/bin/sleep")
        terminal.arguments = ["30"]
        try terminal.run()
        defer { terminal.terminate() }
        let copy = getpid()
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSessionRecords(
            in: home,
            [
                terminal.processIdentifier:
                    #"{"pid":\#(terminal.processIdentifier),"kind":"interactive","parkedJobId":"job1"}"#,
                copy: #"{"pid":\#(copy),"kind":"bg","jobId":"job1"}"#,
            ])
        var log: [String] = []
        let supervisor = try makeSupervisor(
            onNotableEvent: { log.append($0) }, home: home, agentProcessStartedAt: AgentProcessLocator.startTime(of:))
        supervisor.ingest(
            testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: terminal.processIdentifier))
        supervisor.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: copy))
        XCTAssertEqual(supervisor.sessions.first?.viewerProcessID, terminal.processIdentifier)

        terminal.terminate()
        terminal.waitUntilExit()
        let deadline = Date().addingTimeInterval(3)
        while supervisor.sessions.first?.viewerProcessID != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        let row = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertNil(row.viewerProcessID)
        XCTAssertEqual(row.hostKind, .background)
        XCTAssertEqual(row.phase, .idle, "the session runs on; only its window went")
        XCTAssertEqual(log.filter { $0.contains("its terminal is gone") }.count, 1, "\(log)")
    }

    /// The viewer is remembered with the row, and vouched for again on the next launch like
    /// the agent itself: a terminal closed while the app was down is no viewer, and the row
    /// comes back as a background one, with `claude attach` behind the click.
    func testARememberedViewerThatIsGoneIsDroppedOnRestore() throws {
        // Real numbers, because a restored row is vouched for by the real process table: this
        // process stands in for the copy, and a child that has already exited for the terminal.
        let copy = getpid()
        let terminal = try exitedProcessID()
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSessionRecords(
            in: home,
            [
                terminal: #"{"pid":\#(terminal),"kind":"interactive","parkedJobId":"job1"}"#,
                copy: #"{"pid":\#(copy),"kind":"bg","jobId":"job1"}"#,
            ])
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let before = try makeSupervisor(
            now: { Date() },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home,
            // Both alive at the first launch, as far as the viewer lookup is concerned.
            agentProcessStartedAt: { _ in Date(timeIntervalSince1970: 3_900) }
        )
        before.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: terminal))
        before.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: copy))
        XCTAssertEqual(before.sessions.first?.viewerProcessID, terminal)
        before.stop()

        var log: [String] = []
        let after = try makeSupervisor(
            now: { Date() },
            onNotableEvent: { log.append($0) },
            history: SessionHistoryStore(directoryURL: directory),
            settings: settings,
            home: home,
            agentProcessStartedAt: AgentProcessLocator.startTime(of:)
        )
        after.start()
        defer { after.stop() }

        let row = try XCTUnwrap(after.sessions.first)
        XCTAssertEqual(after.sessions.count, 1)
        XCTAssertNil(row.viewerProcessID)
        XCTAssertEqual(row.hostKind, .background)
        XCTAssertEqual(row.agentProcessID, copy, "the row itself is vouched for by the copy")
        XCTAssertEqual(log.filter { $0.contains("its terminal is gone") }.count, 1, "\(log)")
    }

    /// The same launch with the terminal still there keeps the row reachable through it.
    func testARememberedViewerStillThereIsKeptOnRestore() throws {
        let copy = getpid()
        let terminal = getppid()
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSessionRecords(
            in: home,
            [
                terminal: #"{"pid":\#(terminal),"kind":"interactive","parkedJobId":"job1"}"#,
                copy: #"{"pid":\#(copy),"kind":"bg","jobId":"job1"}"#,
            ])
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try makeSettings()
        let before = try makeSupervisor(
            now: { Date() }, history: SessionHistoryStore(directoryURL: directory), settings: settings,
            home: home, agentProcessStartedAt: AgentProcessLocator.startTime(of:))
        before.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: terminal))
        before.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: copy))
        before.stop()

        let after = try makeSupervisor(
            now: { Date() }, history: SessionHistoryStore(directoryURL: directory), settings: settings,
            home: home, agentProcessStartedAt: AgentProcessLocator.startTime(of:))
        after.start()
        defer { after.stop() }

        XCTAssertEqual(after.sessions.first?.viewerProcessID, terminal)
        XCTAssertEqual(after.sessions.first?.hostKind, .cli)
    }

    /// A copy the sender could not trace — `source: "fork"` on its start and no original named
    /// — is a row of its own, and the log says why, so a second row for one conversation never
    /// appears in silence.
    func testACopyWithNoNamedOriginalIsARowOfItsOwnAndSaysSo() throws {
        var log: [String] = []
        let supervisor = try makeSupervisor(onNotableEvent: { log.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: 501))

        supervisor.ingest(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "SessionStart",
                payload: .object(["session_id": .string("beta"), "source": .string("fork")]),
                agentProcessID: 502
            )
        )

        XCTAssertEqual(supervisor.sessions.count, 2)
        XCTAssertEqual(log.filter { $0.contains("copy of a session this app cannot name") }.count, 1, "\(log)")
    }

    /// After `/fork` the copy often ends first, and its end closes the row — then the person
    /// keeps typing in the session itself. The row comes back for it, with the watch that will
    /// report its death armed again, and the journal says what happened rather than claiming
    /// two sessions run side by side.
    func testASessionWhoseCopyClosedTheRowComesBackWhenItSpeaks() throws {
        var clock = start
        var log: [String] = []
        // This process stands in for the session's own, so that the watch on it is a real one
        // and the sweep below can tell an armed watch from none.
        let terminal = ProcessInfo.processInfo.processIdentifier
        let supervisor = try makeSupervisor(now: { clock }, onNotableEvent: { log.append($0) })
        supervisor.ingest(testRequest(event: "SessionStart", sessionID: "alpha", agentProcessID: terminal))
        supervisor.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: 502))
        supervisor.ingest(copyRequest(event: "SessionEnd", sessionID: "beta", of: "alpha", agentProcessID: 502))
        let closed = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(closed.phase, .sessionClosed)

        supervisor.ingest(testRequest(event: "UserPromptSubmit", sessionID: "alpha", agentProcessID: terminal))

        let row = try XCTUnwrap(supervisor.sessions.first)
        XCTAssertEqual(supervisor.sessions.count, 1, "one row, and it is the session's own again")
        XCTAssertEqual(row.id, closed.id)
        XCTAssertEqual(row.phase, .executing)
        XCTAssertEqual(row.agentProcessID, terminal)
        XCTAssertEqual(log.filter { $0.contains("reopened") }.count, 1, "\(log)")
        XCTAssertTrue(log.allSatisfy { !$0.contains("works on beside") }, "the copy is dead, not working: \(log)")

        // Closing the row took its watch away with it. If the reopen did not arm one again,
        // nothing would ever report this session's death — and the sweep, which spares only
        // the sessions a watcher vouches for, would demote it after half an hour.
        clock = start.addingTimeInterval(SessionFreshnessEvaluator.defaultDisconnectAfter + 1)
        supervisor.runMaintenance()

        XCTAssertEqual(supervisor.sessions.first?.phase, .executing, "a watcher vouches for it again")
    }

    /// The app may start with no memory of the session while `/bg` has already run, and then
    /// the scan builds a row for the parked terminal too: a live `claude` with nothing heard
    /// from it. A row like that runs no conversation the app knows of, and must not keep the
    /// terminal from being the copy's viewer — or the copy's row would stay a background one
    /// on every hook, beside a nameless row for the terminal, for good. Named as the viewer,
    /// the terminal is claimed, and the next scan withdraws its row.
    func testARowTheScanBuiltForTheParkedTerminalDoesNotBlockTheViewer() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSessionRecords(
            in: home,
            [
                501: #"{"pid":501,"kind":"interactive","parkedJobId":"job1"}"#,
                502: #"{"pid":502,"kind":"bg","jobId":"job1"}"#,
            ])
        let startedAt = Date(timeIntervalSince1970: 3_900)
        let supervisor = try makeSupervisor(
            home: home,
            liveAgentProcesses: {
                [
                    DiscoveredAgentProcess(source: .claude, processID: 501, startedAt: startedAt, projectName: "p"),
                    DiscoveredAgentProcess(
                        source: .claude, processID: 502, startedAt: startedAt, projectName: "p", clientKind: .background
                    ),
                ]
            },
            agentProcessStartedAt: { _ in startedAt }
        )
        supervisor.start()
        defer { supervisor.stop() }
        XCTAssertEqual(supervisor.sessions.count, 2, "a row per process found, nothing heard from either")

        supervisor.ingest(copyRequest(event: "SessionStart", sessionID: "beta", of: "alpha", agentProcessID: 502))

        let copy = try XCTUnwrap(supervisor.sessions.first { $0.agentProcessID == 502 })
        XCTAssertEqual(copy.viewerProcessID, 501, "the terminal shows it, whatever row the scan gave the terminal")
        supervisor.discoverAgentProcesses()
        XCTAssertEqual(supervisor.sessions.map(\.agentProcessID), [502], "the terminal's own row is withdrawn")
    }

    private func makeSupervisor(
        retention: ClosedSessionRetention = .manual,
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 4_000) },
        onChange: @escaping ([SessionSnapshot], [AgentUsageLimits]) -> Void = { _, _ in },
        onNotableEvent: @escaping (String) -> Void = { _ in },
        heard: AgentHeardStore? = nil,
        history: SessionHistoryStore? = nil,
        settings: WidgetSettingsStore? = nil,
        home: URL? = nil,
        workspaceNotifications: NotificationCenter = NotificationCenter(),
        // Nothing by default, and never the real scanner: a test that started the app would
        // otherwise find whatever agents happen to be running on the machine it runs on.
        liveAgentProcesses: @escaping () -> [DiscoveredAgentProcess] = { [] },
        // No start time by default, and never the real one, for the same reason: a test's
        // process numbers are made up, and answering for them would pair a session with
        // whatever is running under that number on this machine.
        agentProcessStartedAt: @escaping (Int32) -> Date? = { _ in nil }
    ) throws -> SessionSupervisor {
        // A test that starts the app twice passes the store it already has, so both launches
        // read one settings file — the same thing that makes them share `history`.
        let settings = try settings ?? makeSettings()
        settings.setClosedSessionRetention(retention)
        // No transcript is ever found under an empty directory, which is what these tests
        // want: the transcript arrives through `applyTranscript`, stated rather than read.
        return SessionSupervisor(
            settings: settings,
            home: home ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            heard: heard
                ?? AgentHeardStore(
                    directoryURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                ),
            history: history
                ?? SessionHistoryStore(
                    directoryURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                ),
            workspaceNotifications: workspaceNotifications,
            now: now,
            liveAgentProcesses: liveAgentProcesses,
            agentProcessStartedAt: agentProcessStartedAt,
            onChange: onChange,
            onNotableEvent: onNotableEvent
        )
    }

    private func makeSettings() throws -> WidgetSettingsStore {
        WidgetSettingsStore(preferences: try isolatedPreferences())
    }

    private func toolCall(sessionID: String, toolUseID: String) -> HookIngressRequest {
        HookIngressRequest(
            source: .claude,
            declaredEvent: "PreToolUse",
            payload: .object([
                "session_id": .string(sessionID),
                "tool_name": .string("Bash"),
                "tool_use_id": .string(toolUseID),
            ])
        )
    }

    private func hasWork(phases: [SessionPhase], retention: ClosedSessionRetention) -> Bool {
        let sessions = phases.enumerated().map { index, phase in
            testSession(index: index, phase: phase, lastObservedAt: start)
        }
        return SessionSupervisor.hasMaintenanceWork(sessions: sessions, retention: retention)
    }
}
