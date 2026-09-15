import Foundation
import XCTest

@testable import AgentWatchCore

final class EventProtocolTests: XCTestCase {
    /// What each tool name arrives as — through the redactor, not around it.
    ///
    /// Asking `activityKind(forToolNamed:)` directly is a test that cannot fail: the redactor
    /// replaces any name outside its allowlist with `<redacted>` before the normalizer sees
    /// it, so the old version asserted an answer for `"Agent"` on a string the socket can
    /// never deliver.
    func testWhatKindOfWorkEachToolNameArrivesAs() throws {
        XCTAssertEqual(try activityKind(ofToolNamed: "Bash"), .shell)
        XCTAssertEqual(try activityKind(ofToolNamed: "Read"), .tool)
        // A call to the subagent tool is an ordinary tool call however it arrives — the
        // subagent itself comes from `SubagentStart`, see `testOneSubagentIsCountedOnce`.
        // Here it also happens to be unnameable: `Agent` is not on the allowlist, and neither
        // is any MCP tool. Measured over six recent transcripts, that is 12% of all calls.
        XCTAssertEqual(try activityKind(ofToolNamed: "Agent"), .tool)
        XCTAssertEqual(try activityKind(ofToolNamed: "mcp__claude_ai_Atlassian__getJiraIssue"), .tool)
    }

    private func activityKind(ofToolNamed toolName: String) throws -> ActivityKind? {
        let request = HookIngressRequest(
            source: .claude,
            declaredEvent: "PreToolUse",
            payload: .object([
                "session_id": .string("session"),
                "tool_use_id": .string("tool"),
                "tool_name": .string(toolName),
            ])
        )
        return try HookIngressProcessor.normalize(request, observedAt: start).activityKind
    }

    /// The identifier that tells a subagent's call from the main thread's, end to end.
    ///
    /// Through `HookIngressProcessor` rather than the normalizer directly, because
    /// `agent_id` is hashed on the way in — twice, once by the sender and once by the app —
    /// and what this test is actually about is that the two hooks still agree afterwards.
    /// The subagent's own activity is identified by its `agent_id`, and the calls it makes
    /// name that same value as their parent; asserting on raw strings would prove neither.
    ///
    /// Measured on Claude Code 2.1.272: `agent_id` is present on every hook fired from
    /// inside a subagent and absent on the main thread's.
    func testASubagentsCallsNameTheSubagentTheyBelongTo() throws {
        let subagentStarted = try HookIngressProcessor.normalize(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "SubagentStart",
                payload: .object([
                    "session_id": .string("session"),
                    "agent_id": .string("agent-a"),
                ])
            ),
            observedAt: start
        )
        let itsCall = try HookIngressProcessor.normalize(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "PreToolUse",
                payload: .object([
                    "session_id": .string("session"),
                    "agent_id": .string("agent-a"),
                    "tool_use_id": .string("tool"),
                    "tool_name": .string("Bash"),
                ])
            ),
            observedAt: start
        )
        let mainThreadCall = try HookIngressProcessor.normalize(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "PreToolUse",
                payload: .object([
                    "session_id": .string("session"),
                    "tool_use_id": .string("tool"),
                    "tool_name": .string("Bash"),
                ])
            ),
            observedAt: start
        )

        XCTAssertEqual(
            itsCall.agentID,
            subagentStarted.activityID,
            "a call made inside a subagent names the very activity that subagent is"
        )
        XCTAssertNil(mainThreadCall.agentID, "the main thread's hooks carry no agent of their own")
    }

    /// `SubagentStart` reports the subagent's own `agent_id`, which is also what its activity
    /// is identified by — so read blindly it would come out as its own parent. Nothing owns
    /// itself. (What a subagent nested inside another reports is not measured.)
    func testTheSubagentActivityIsNotItsOwnParent() throws {
        let started = try HookIngressProcessor.normalize(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "SubagentStart",
                payload: .object([
                    "session_id": .string("session"),
                    "agent_id": .string("agent-a"),
                ])
            ),
            observedAt: start
        )

        XCTAssertNil(started.agentID)
    }

    private let start = Date(timeIntervalSince1970: 2_000)

    func testClaudeFixtureNormalizesEachLifecycleTransition() throws {
        let snapshots = try ingestFixture(named: "claude-basic-lifecycle")

        XCTAssertEqual(snapshots.map(\.source), [.claude, .claude, .claude, .claude, .claude])
        XCTAssertEqual(
            snapshots.map(\.phase),
            [.idle, .executing, .executing, .executing, .completed]
        )
        XCTAssertEqual(snapshots[0].mode, .unknown)
        XCTAssertEqual(snapshots[1].mode, .standard)
        XCTAssertEqual(snapshots[2].activities.count, 1)
        XCTAssertTrue(snapshots[3].activities.isEmpty)
    }

    func testCodexFixtureNormalizesEachLifecycleTransition() throws {
        let snapshots = try ingestFixture(named: "codex-basic-lifecycle")

        XCTAssertEqual(snapshots.map(\.source), [.codex, .codex, .codex, .codex, .codex])
        XCTAssertEqual(
            snapshots.map(\.phase),
            [.idle, .executing, .executing, .executing, .completed]
        )
        XCTAssertEqual(snapshots[2].activities.first?.kind, .shell)
        XCTAssertTrue(snapshots[3].activities.isEmpty)
    }

    func testPreToolUseMapsBashToShellActivity() throws {
        let fixture = try fixtureEvents(named: "codex-basic-lifecycle")[2]
        let event = try HookEventNormalizer.normalize(
            source: fixture.source,
            declaredEvent: fixture.declaredEvent,
            payload: fixture.payload,
            observedAt: start
        )

        XCTAssertEqual(event.kind, .activityStarted)
        XCTAssertEqual(event.activityKind, .shell)
    }

    func testPlanPermissionModeMapsToPlanMode() throws {
        let payload: JSONValue = .object([
            "session_id": .string("id_session"),
            "permission_mode": .string("plan"),
        ])

        let event = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "UserPromptSubmit",
            payload: payload,
            observedAt: start
        )

        XCTAssertEqual(event.kind, .turnStarted)
        XCTAssertEqual(event.mode, .plan)

        var engine = SessionStateEngine()
        let snapshot = try engine.ingest(event)
        XCTAssertEqual(snapshot.phase, .planning)
    }

    func testPermissionRequestMapsToUserInputRequired() throws {
        let payload: JSONValue = .object(["session_id": .string("id_session")])

        let event = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "PermissionRequest",
            payload: payload,
            observedAt: start
        )

        XCTAssertEqual(event.kind, .userInputRequired)
    }

    func testAskUserQuestionMapsToUserInputRequired() throws {
        let payload: JSONValue = .object([
            "session_id": .string("id_session"),
            "tool_use_id": .string("id_question"),
            "tool_name": .string("AskUserQuestion"),
        ])

        let event = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "PreToolUse",
            payload: payload,
            observedAt: start
        )

        XCTAssertEqual(event.kind, .userInputRequired)
    }

    func testSubagentHooksTrackTheAgentAsAnActivity() throws {
        let payload: JSONValue = .object([
            "session_id": .string("id_session"),
            "agent_id": .string("id_subagent"),
        ])

        let started = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "SubagentStart",
            payload: payload,
            observedAt: start
        )
        let stopped = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "SubagentStop",
            payload: payload,
            observedAt: start.addingTimeInterval(1)
        )

        XCTAssertEqual(started.kind, .activityStarted)
        XCTAssertEqual(started.activityKind, .subagent)
        // The one call that may still be running after its turn ends.
        XCTAssertTrue(started.activityOutlivesTurn)
        XCTAssertEqual(stopped.kind, .activityCompleted)
        XCTAssertEqual(started.activityID, stopped.activityID)
    }

    /// `PostToolUse` fires only when a call succeeds. Listening for it alone left a refused
    /// or failed call open forever, which the widget then reported as work in flight.
    ///
    /// Success and failure are separate kinds because they mean different things about what
    /// the call left behind: a successful background shell is still running, a refused one
    /// never started.
    func testEveryReportedEndingOfAToolCallIsRecognised() throws {
        let payload: JSONValue = .object([
            "session_id": .string("id_session"),
            "tool_use_id": .string("id_call"),
            "tool_name": .string("Agent"),
        ])
        let expected: [String: EventKind] = [
            "PostToolUse": .activityCompleted,
            "PostToolUseFailure": .activityFailed,
            "PermissionDenied": .activityFailed,
        ]

        for (declaredEvent, kind) in expected {
            let event = try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: declaredEvent,
                payload: payload,
                observedAt: start
            )

            XCTAssertEqual(event.kind, kind, declaredEvent)
            XCTAssertEqual(event.activityID, "id_call", declaredEvent)
        }
    }

    /// A background shell is its own kind of work, and the end of its call is not the end of
    /// the command. Measured on real transcripts: the call reports back in about five
    /// seconds while the command runs on.
    ///
    /// Where the work does end is a separate question, covered by the two tests below.
    func testABackgroundShellIsShownAsBackgroundWorkAndOutlivesItsOwnCall() throws {
        var engine = SessionStateEngine()
        let call: JSONValue = .object([
            "session_id": .string("id_session"),
            "tool_use_id": .string("id_call"),
            "tool_name": .string("Bash"),
        ])

        let started = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "PreToolUse",
            payload: call,
            observedAt: start,
            toolRunsInBackground: true
        )

        XCTAssertEqual(started.activityKind, .backgroundTask)
        XCTAssertTrue(started.activityOutlivesItsCall)
        XCTAssertTrue(started.activityOutlivesTurn, "the command keeps running after the turn ends")

        _ = try engine.ingest(started)
        let afterCall = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "PostToolUse",
                payload: call,
                observedAt: start.addingTimeInterval(5)
            )
        )

        XCTAssertEqual(afterCall.activities.map(\.kind), [.backgroundTask], "still running")
    }

    func testAShellTheAgentWaitsForStaysAnOrdinaryShell() throws {
        let started = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "PreToolUse",
            payload: .object([
                "session_id": .string("id_session"),
                "tool_use_id": .string("id_call"),
                "tool_name": .string("Bash"),
            ]),
            observedAt: start,
            toolRunsInBackground: false
        )

        XCTAssertEqual(started.activityKind, .shell)
        XCTAssertFalse(started.activityOutlivesItsCall)
    }

    func testATurnEndingInAnErrorIsNotATurnThatCompleted() throws {
        var engine = SessionStateEngine()
        let payload: JSONValue = .object(["session_id": .string("id_session")])

        let failed = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "StopFailure",
            payload: payload,
            observedAt: start
        )

        XCTAssertEqual(failed.kind, .turnFailed)

        let snapshot = try engine.ingest(failed)

        XCTAssertEqual(snapshot.phase, .failed)
    }

    /// What replaced `PostToolUse`, and the reason it is not asked for.
    ///
    /// A tool call is closed by two things that were always there. This is the second one:
    /// the end of a turn sweeps every activity that does not outlive it, so a call whose
    /// ending nobody reported cannot survive its own turn. The first is the transcript, which
    /// closes it sooner — see `testTheTranscriptClosesACallNoHookEverClosed`.
    ///
    /// So a hook per tool call bought freshness measured in seconds for a process launch
    /// measured at 0.78 s, and that trade was refused. This is the test that has to fail
    /// before anyone puts the hook back.
    func testAToolCallIsClosedByTheEndOfItsTurnWithNoPostToolUse() throws {
        var engine = SessionStateEngine()
        let session: JSONValue = .object(["session_id": .string("id_session")])
        for event in ["SessionStart", "UserPromptSubmit"] {
            try engine.ingest(
                HookEventNormalizer.normalize(
                    source: .claude, declaredEvent: event, payload: session, observedAt: start))
        }
        let running = try engine.ingest(
            HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "PreToolUse",
                payload: .object([
                    "session_id": .string("id_session"),
                    "tool_use_id": .string("id_call"),
                    "tool_name": .string("Bash"),
                ]),
                observedAt: start + 1
            ))
        XCTAssertEqual(running.activities.count, 1, "the call is open, and no hook will close it")

        let ended = try engine.ingest(
            HookEventNormalizer.normalize(
                source: .claude, declaredEvent: "Stop", payload: session, observedAt: start + 2))

        XCTAssertTrue(ended.activities.isEmpty, "a call with no reported ending dies with its turn")
        XCTAssertEqual(ended.phase, .completed)
    }

    /// Codex reports an interruption outright. Claude does not — there the same fact has to
    /// be dug out of the transcript, which is why reading it on silence exists at all.
    ///
    /// What makes the hook worth registering is the landing: `idle`, with nothing running.
    /// `completed` would say the work a person stopped had finished, and a green lamp on a
    /// turn somebody cancelled states the opposite of what happened.
    func testAnInterruptedCodexTurnStopsEverythingAndSettlesIdle() throws {
        var engine = SessionStateEngine()
        let session: JSONValue = .object(["session_id": .string("id_session")])
        for event in ["SessionStart", "UserPromptSubmit"] {
            try engine.ingest(
                HookEventNormalizer.normalize(
                    source: .codex, declaredEvent: event, payload: session, observedAt: start))
        }
        let running = try engine.ingest(
            HookEventNormalizer.normalize(
                source: .codex,
                declaredEvent: "PreToolUse",
                payload: .object([
                    "session_id": .string("id_session"),
                    "tool_use_id": .string("id_call"),
                    "tool_name": .string("Bash"),
                ]),
                observedAt: start + 1
            ))
        XCTAssertEqual(running.activities.count, 1)

        let interrupted = try HookEventNormalizer.normalize(
            source: .codex,
            declaredEvent: "Interrupt",
            payload: session,
            observedAt: start + 2
        )

        XCTAssertEqual(interrupted.kind, .turnInterrupted)

        let snapshot = try engine.ingest(interrupted)

        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertTrue(snapshot.activities.isEmpty, "the interruption is aimed at the whole turn")
    }

    /// The reported bug, end to end: a subagent tool call the user refused. Before this the
    /// session was left claiming to wait for a subtask that had never started.
    func testARefusedSubagentCallDoesNotLeaveTheSessionWaitingForSubtasks() throws {
        var engine = SessionStateEngine()
        let call: JSONValue = .object([
            "session_id": .string("id_session"),
            "tool_use_id": .string("id_call"),
            "tool_name": .string("Agent"),
        ])

        for (index, declaredEvent) in ["UserPromptSubmit", "PreToolUse", "PermissionRequest"].enumerated() {
            let event = try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: declaredEvent,
                payload: call,
                observedAt: start.addingTimeInterval(TimeInterval(index))
            )
            _ = try engine.ingest(event)
        }

        let denied = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "PermissionDenied",
            payload: call,
            observedAt: start.addingTimeInterval(3)
        )
        let afterDenial = try engine.ingest(denied)

        XCTAssertTrue(afterDenial.activities.isEmpty)

        let stopped = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "Stop",
            payload: .object(["session_id": .string("id_session")]),
            observedAt: start.addingTimeInterval(4)
        )
        let afterStop = try engine.ingest(stopped)

        XCTAssertEqual(afterStop.phase, .completed)
        XCTAssertTrue(afterStop.activities.isEmpty)
    }

    /// Compaction is why a session can go quiet for a while without waiting on anything, so
    /// it is shown as work of its own rather than left unexplained.
    func testCompactionIsShownAsWorkAndEndsWithItsOwnEvent() throws {
        var engine = SessionStateEngine()
        let payload: JSONValue = .object(["session_id": .string("id_session")])

        let started = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "PreCompact",
            payload: payload,
            observedAt: start
        )

        XCTAssertEqual(started.kind, .activityStarted)
        XCTAssertEqual(started.activityKind, .compaction)

        _ = try engine.ingest(started)
        let finished = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "PostCompact",
                payload: payload,
                observedAt: start.addingTimeInterval(6)
            )
        )

        XCTAssertTrue(finished.activities.isEmpty, "the pair shares one identifier, so it closes")
    }

    /// Compaction can fail, and then no `PostCompact` arrives. The end of the turn is the
    /// bound — the same rule that clears any other call nobody reported the end of.
    func testACompactionThatNeverReportedItsEndIsClearedByTheTurn() throws {
        var engine = SessionStateEngine()
        let payload: JSONValue = .object(["session_id": .string("id_session")])

        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "PreCompact",
                payload: payload,
                observedAt: start
            )
        )
        let afterStop = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "Stop",
                payload: payload,
                observedAt: start.addingTimeInterval(30)
            )
        )

        XCTAssertTrue(afterStop.activities.isEmpty)
        XCTAssertEqual(afterStop.phase, .completed)
    }

    /// A background shell outlives the turn that started it. Measured against this project's
    /// own event log: a task started at 00:08:52 handed back its handle at 00:08:57, `Stop`
    /// arrived at 00:09:21, and the script itself only finished at 00:12:16 — so for almost
    /// three minutes the widget dropped the row and called the session finished.
    ///
    /// Built from hook events rather than from a hand-made activity: the reducer already
    /// kept a background task that said it outlived the turn, and the normalizer never made
    /// one, so a test that assembled the activity itself passed while the product was wrong.
    func testABackgroundShellSurvivesTheStopOfItsOwnTurn() throws {
        var engine = SessionStateEngine()
        let session: JSONValue = .string("id_session")
        let call: JSONValue = .object([
            "session_id": session,
            "tool_use_id": .string("id_background"),
            "tool_name": .string("Bash"),
        ])

        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "PreToolUse",
                payload: call,
                observedAt: start,
                toolRunsInBackground: true
            )
        )
        // The call reporting success is the handle coming back, not the command ending.
        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "PostToolUse",
                payload: call,
                observedAt: start.addingTimeInterval(5)
            )
        )
        let afterStop = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "Stop",
                payload: .object(["session_id": session]),
                observedAt: start.addingTimeInterval(29)
            )
        )

        XCTAssertEqual(afterStop.activities.map(\.kind), [.backgroundTask])
        XCTAssertEqual(afterStop.phase, .waitingForChildren)
    }

    /// The next turn is where background work ends, because the notification of its ending is
    /// what starts that turn. A subagent is the opposite case in the same sweep: `SubagentStop`
    /// reports its end, so a new prompt must not take it away.
    func testTheNextTurnEndsBackgroundWorkButNotASubagent() throws {
        var engine = SessionStateEngine()
        let session: JSONValue = .string("id_session")

        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "PreToolUse",
                payload: .object([
                    "session_id": session,
                    "tool_use_id": .string("id_background"),
                    "tool_name": .string("Bash"),
                ]),
                observedAt: start,
                toolRunsInBackground: true
            )
        )
        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "SubagentStart",
                payload: .object(["session_id": session, "agent_id": .string("id_agent")]),
                observedAt: start.addingTimeInterval(1)
            )
        )
        let afterNextTurn = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "UserPromptSubmit",
                payload: .object(["session_id": session]),
                observedAt: start.addingTimeInterval(180)
            )
        )

        XCTAssertEqual(afterNextTurn.activities.map(\.kind), [.subagent])
        XCTAssertEqual(afterNextTurn.phase, .executing)
    }

    /// One subagent must be counted once. Its tool call and its own `SubagentStart` are two
    /// events with different identifiers, so naming both a subagent showed two subagents for
    /// the two seconds the call takes to return.
    func testOneSubagentIsCountedOnce() throws {
        var engine = SessionStateEngine()
        let session: JSONValue = .string("id_session")
        let call: JSONValue = .object([
            "session_id": session,
            "tool_use_id": .string("id_call"),
            "tool_name": .string("Agent"),
        ])
        let subagent: JSONValue = .object([
            "session_id": session,
            "agent_id": .string("id_agent"),
        ])

        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude, declaredEvent: "PreToolUse", payload: call, observedAt: start
            )
        )
        let running = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude, declaredEvent: "SubagentStart", payload: subagent,
                observedAt: start.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(running.activities.filter { $0.kind == .subagent }.count, 1)
        XCTAssertEqual(running.activities.filter { $0.kind == .tool }.count, 1, "the call is a call")

        // The call hands back its handle; the subagent runs on.
        let afterCall = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude, declaredEvent: "PostToolUse", payload: call,
                observedAt: start.addingTimeInterval(2)
            )
        )

        XCTAssertEqual(afterCall.activities.map(\.kind), [.subagent])

        // The parent's turn ends while the subagent is still working.
        let afterStop = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude, declaredEvent: "Stop",
                payload: .object(["session_id": session]), observedAt: start.addingTimeInterval(3)
            )
        )

        XCTAssertEqual(afterStop.phase, .waitingForChildren)
        XCTAssertEqual(afterStop.activities.map(\.kind), [.subagent])

        let finished = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude, declaredEvent: "SubagentStop", payload: subagent,
                observedAt: start.addingTimeInterval(60)
            )
        )

        XCTAssertTrue(finished.activities.isEmpty)
        XCTAssertEqual(finished.phase, .completed)
    }

    /// A fork's hooks name the session it continues, and the envelope carries that name on
    /// every event rather than on the start alone: the app may not have been running when the
    /// fork started, and the first event it hears is then the one that has to say so.
    func testAForkNamesTheSessionItContinues() throws {
        let fork: JSONValue = .object([
            "session_id": .string("id_fork"),
            "forked_from_session_id": .string("id_original"),
        ])

        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            let envelope = try HookEventNormalizer.normalize(
                source: .claude, declaredEvent: event, payload: fork, observedAt: start)
            XCTAssertEqual(envelope.forkedFromSessionID, "id_original", event)
        }

        let plain = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "SessionStart",
            payload: .object(["session_id": .string("id_session")]),
            observedAt: start
        )
        XCTAssertNil(plain.forkedFromSessionID)
    }

    /// The documented mark of a copy is `source: "fork"` on its start. Carried so that a copy
    /// whose original the sender could not name is at least said out loud, rather than drawn
    /// as a second row in silence. Only a start says it; the word means nothing elsewhere.
    func testAStartSaysWhetherTheSessionIsACopy() throws {
        let copy = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "SessionStart",
            payload: .object(["session_id": .string("id_fork"), "source": .string("fork")]),
            observedAt: start
        )
        XCTAssertTrue(copy.startedAsCopy)

        let fresh = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "SessionStart",
            payload: .object(["session_id": .string("id_session"), "source": .string("startup")]),
            observedAt: start
        )
        XCTAssertFalse(fresh.startedAsCopy)

        let turn = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "UserPromptSubmit",
            payload: .object(["session_id": .string("id_fork"), "source": .string("fork")]),
            observedAt: start
        )
        XCTAssertFalse(turn.startedAsCopy)
    }

    func testEventEnvelopeRoundTripsThroughJSON() throws {
        let event = EventEnvelope(
            source: .codex,
            sessionID: "id_session",
            activityID: "id_tool",
            observedAt: start,
            kind: .activityStarted,
            mode: .plan,
            activityKind: .shell
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(EventEnvelope.self, from: encoder.encode(event)), event)
    }

    func testSameRawSessionIDFromDifferentSourcesStaysSeparate() throws {
        var engine = SessionStateEngine()

        let claude = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "id_session",
                observedAt: start,
                kind: .sessionStarted
            )
        )
        let codex = try engine.ingest(
            EventEnvelope(
                source: .codex,
                sessionID: "id_session",
                observedAt: start,
                kind: .sessionStarted
            )
        )

        XCTAssertEqual(engine.snapshots.count, 2)
        XCTAssertNotEqual(claude.id, codex.id)
        XCTAssertEqual(claude.source, .claude)
        XCTAssertEqual(codex.source, .codex)
    }

    func testRejectsAnUnsupportedEnvelopeSchemaVersion() {
        var engine = SessionStateEngine()
        let event = EventEnvelope(
            schemaVersion: EventEnvelope.currentSchemaVersion + 1,
            source: .claude,
            sessionID: "id_session",
            observedAt: start,
            kind: .sessionStarted
        )

        XCTAssertThrowsError(try engine.ingest(event)) { error in
            XCTAssertEqual(
                error as? EventIngestionError,
                .unsupportedSchemaVersion(EventEnvelope.currentSchemaVersion + 1)
            )
        }
    }

    func testIngressRequestIsRedactedBeforeNormalization() throws {
        let request = HookIngressRequest(
            source: .claude,
            declaredEvent: "PreToolUse",
            payload: .object([
                "session_id": .string("session-secret"),
                "tool_use_id": .string("tool-secret"),
                "tool_name": .string("Bash"),
                "tool_input": .object(["command": .string("cat .env")]),
            ])
        )

        let event = try HookIngressProcessor.normalize(request, observedAt: start)

        XCTAssertEqual(event.kind, .activityStarted)
        XCTAssertEqual(event.activityKind, .shell)
        XCTAssertTrue(event.sessionID.hasPrefix("id_"))
        XCTAssertNotEqual(event.sessionID, "session-secret")
    }

    func testLocalControlRejectsAnUnsupportedSchemaVersion() {
        let request = HookIngressRequest(
            schemaVersion: 0,
            source: .codex,
            declaredEvent: LocalAgentWatchControl.revealExistingInstanceEvent,
            payload: .object([:])
        )

        XCTAssertFalse(LocalAgentWatchControl.isRevealExistingInstance(request))
    }

    func testIngressKeepsDeclaredClaudeProcessIdentityOutsideRedactedPayload() throws {
        let request = HookIngressRequest(
            source: .claude,
            declaredEvent: "UserPromptSubmit",
            payload: .object([
                "session_id": .string("session-secret"),
                "prompt": .string("private prompt"),
            ]),
            agentProcessID: 4_242
        )

        let event = try HookIngressProcessor.normalize(request, observedAt: start)
        var engine = SessionStateEngine()
        let snapshot = try engine.ingest(event)

        XCTAssertEqual(event.agentProcessID, 4_242)
        XCTAssertEqual(snapshot.agentProcessID, 4_242)
    }

    func testClosingKnownSessionPreservesFactThatItsAgentProcessExited() throws {
        var engine = SessionStateEngine()
        let started = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "id_session",
                observedAt: start,
                kind: .turnStarted,
                agentProcessID: 4_242
            )
        )

        let closed = try XCTUnwrap(
            engine.markSessionClosed(id: started.id, at: start.addingTimeInterval(1))
        )

        XCTAssertEqual(closed.phase, .sessionClosed)
        XCTAssertEqual(closed.agentProcessID, 4_242)
        XCTAssertTrue(closed.activities.isEmpty)
    }

    func testRemovingAClosedSessionRemovesItFromTheEngine() throws {
        var engine = SessionStateEngine()
        let started = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "id_session",
                observedAt: start,
                kind: .sessionStarted
            )
        )
        _ = engine.markSessionClosed(id: started.id, at: start.addingTimeInterval(1))

        XCTAssertEqual(engine.removeSession(id: started.id)?.id, started.id)
        XCTAssertTrue(engine.snapshots.isEmpty)
        XCTAssertNil(engine.removeSession(id: started.id))
    }

    func testSessionStartReopensAClosedSessionWithItsNewProcessIdentity() throws {
        var engine = SessionStateEngine()
        let started = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "id_session",
                observedAt: start,
                kind: .turnStarted,
                agentProcessID: 4_242
            )
        )
        _ = engine.markSessionClosed(id: started.id, at: start.addingTimeInterval(1))

        let reopened = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "id_session",
                observedAt: start.addingTimeInterval(2),
                kind: .sessionStarted,
                mode: .plan,
                agentProcessID: 5_555
            )
        )

        XCTAssertEqual(reopened.phase, .idle)
        XCTAssertEqual(reopened.mode, .plan)
        XCTAssertTrue(reopened.activities.isEmpty)
        XCTAssertEqual(reopened.agentProcessID, 5_555)
    }

    func testStatusLineUpdatesClaudeContextAndAggregateUsageWithoutChangingPhase() throws {
        let payload: JSONValue = .object([
            "session_id": .string("id_session"),
            "context_total_input_tokens": .number(85_000),
            "context_used_percentage": .number(42.5),
            "five_hour_used_percentage": .number(17),
            "five_hour_resets_at": .number(2_000_000_000),
            "seven_day_used_percentage": .number(31),
        ])
        let event = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "StatusLine",
            payload: payload,
            observedAt: start,
            clientKind: .cli
        )

        XCTAssertEqual(event.kind, .statusUpdated)
        XCTAssertEqual(event.contextTelemetry, .init(totalInputTokens: 85_000, usedPercentage: 42.5))
        XCTAssertEqual(event.clientKind, .cli)

        var engine = SessionStateEngine()
        _ = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "id_session",
                observedAt: start.addingTimeInterval(-1),
                kind: .turnStarted
            ))
        let snapshot = try engine.ingest(event)

        XCTAssertEqual(snapshot.phase, .executing)
        XCTAssertEqual(snapshot.clientKind, .cli)
        XCTAssertEqual(snapshot.contextTelemetry, .init(totalInputTokens: 85_000, usedPercentage: 42.5))
        XCTAssertEqual(snapshot.lastObservedAt, start.addingTimeInterval(-1))
        XCTAssertEqual(
            engine.usageLimitsBySource[.claude]?.fiveHour,
            .init(usedPercentage: 17)
        )
        XCTAssertEqual(engine.usageLimitsBySource[.claude]?.sevenDay, .init(usedPercentage: 31))
    }

    func testStatusLineRejectsCodexRatherThanInventingSessionUsage() {
        XCTAssertThrowsError(
            try HookEventNormalizer.normalize(
                source: .codex,
                declaredEvent: "StatusLine",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start
            )
        )
    }

    func testDecodedStatusLineRejectsUnrepresentableAndImplausibleTokenCounts() throws {
        for number in ["9223372036854775808", "1e30", "100000001", "-1", "0.5"] {
            let data = Data(
                """
                {"schemaVersion":1,"source":"claude","declaredEvent":"StatusLine",
                 "payload":{"session_id":"session","context_total_input_tokens":\(number),
                 "context_used_percentage":50}}
                """.utf8)
            let request = try JSONDecoder().decode(HookIngressRequest.self, from: data)
            let event = try HookIngressProcessor.normalize(request, observedAt: start)
            XCTAssertNil(event.contextTelemetry, number)
        }
        for count in [0, SessionDescription.maximumContextInputTokens] {
            let event = try HookIngressProcessor.normalize(
                HookIngressRequest(
                    source: .claude,
                    declaredEvent: "StatusLine",
                    payload: .object([
                        "session_id": .string("session"),
                        "context_total_input_tokens": .number(Double(count)),
                        "context_used_percentage": .number(50),
                    ])
                ),
                observedAt: start
            )
            XCTAssertEqual(event.contextTelemetry?.totalInputTokens, count)
        }
    }

    private func ingestFixture(named name: String) throws -> [SessionSnapshot] {
        var engine = SessionStateEngine()
        var snapshots: [SessionSnapshot] = []

        for (index, fixture) in try fixtureEvents(named: name).enumerated() {
            let event = try HookEventNormalizer.normalize(
                source: fixture.source,
                declaredEvent: fixture.declaredEvent,
                payload: fixture.payload,
                observedAt: start.addingTimeInterval(TimeInterval(index))
            )
            snapshots.append(try engine.ingest(event))
        }

        return snapshots
    }

    private func fixtureEvents(named name: String) throws -> [HookFixture] {
        let fixtureURL =
            packageRootURL
            .appendingPathComponent("Fixtures/HookPayloads/\(name).jsonl")
        let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
        let decoder = JSONDecoder()

        return
            try contents
            .split(separator: "\n")
            .map { line in try decoder.decode(HookFixture.self, from: Data(line.utf8)) }
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct HookFixture: Decodable {
    let source: AgentSource
    let declaredEvent: String
    let payload: JSONValue

    /// A refusal has to be sayable out loud, and the only interesting part of it — the event
    /// name — arrives over a socket any process on this machine can write to. So the line is
    /// built where the sanitiser already lives, and stays one line whatever was sent.
    func testARefusalCanBeLoggedWithoutCarryingWhateverArrived() {
        let hostile = EventNormalizationError.unsupportedEvent(
            source: .claude,
            name: "Pre\nToolUse\u{202E}" + String(repeating: "x", count: 500)
        )
        let line = hostile.safeDescription

        XCTAssertFalse(line.contains("\n"), "one refusal is one line")
        XCTAssertFalse(line.contains("\u{202E}"), "nothing that can make the rest read backwards")
        XCTAssertLessThanOrEqual(line.count, 120)

        // The three reasons read differently, because which one it is decides what to do.
        XCTAssertEqual(
            Set(
                [
                    EventNormalizationError.missingSessionID,
                    .missingActivityID,
                    .unsupportedEvent(source: .claude, name: "Whatever"),
                ].map(\.safeDescription)
            ).count,
            3
        )
    }
}
