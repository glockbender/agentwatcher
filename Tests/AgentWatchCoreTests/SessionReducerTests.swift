import AgentWatchTestSupport
import XCTest

@testable import AgentWatchCore

final class SessionReducerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testTurnStartsInPlanningPhaseWhenPlanModeIsReported() {
        let result = SessionReducer.reduce(snapshot(), event: .turnStarted(mode: .plan, at: start))

        XCTAssertEqual(result.mode, .plan)
        XCTAssertEqual(result.phase, .planning)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testTurnStartsInExecutingPhaseAndClearsAttentionWhenStandardModeIsReported() {
        let result = SessionReducer.reduce(
            snapshot(),
            event: .turnStarted(mode: .standard, at: start)
        )

        XCTAssertEqual(result.mode, .standard)
        XCTAssertEqual(result.phase, .executing)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    /// `Stop` is not delivered for every turn — an interrupted one reports nothing — so the
    /// next prompt has to do the sweep instead. Without it the counters showed calls from a
    /// turn that ended minutes ago.
    func testANewPromptDropsCallsLeftOverFromTheTurnBefore() {
        var previous = snapshot(mode: .standard, phase: .executing)
        previous.activities = [activity(id: "never-answered")]

        let result = SessionReducer.reduce(previous, event: .turnStarted(mode: .standard, at: start))

        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertEqual(result.phase, .executing)
    }

    /// The one exception, and the reason the sweep is not `removeAll()`: a subagent spawned by
    /// the previous turn is still working, and the parent being given a new prompt says
    /// nothing about it.
    func testANewPromptKeepsASubagentThatIsStillWorking() {
        var previous = snapshot(mode: .standard, phase: .waitingForChildren)
        previous.activities = [
            activity(id: "never-answered"),
            SessionActivity(id: "child", kind: .subagent, startedAt: start, outlivesTurn: true),
        ]

        let result = SessionReducer.reduce(previous, event: .turnStarted(mode: .standard, at: start))

        XCTAssertEqual(result.activities.map(\.id), ["child"])
    }

    func testModeChangeUpdatesAnActivePhase() {
        let observedAt = start.addingTimeInterval(1)
        let result = SessionReducer.reduce(
            snapshot(mode: .standard, phase: .executing),
            event: .modeChanged(.plan, at: observedAt)
        )

        XCTAssertEqual(result.mode, .plan)
        XCTAssertEqual(result.phase, .planning)
        XCTAssertEqual(result.lastObservedAt, observedAt)
    }

    func testModeChangeReturnsPlanningSessionToExecution() {
        let result = SessionReducer.reduce(
            snapshot(mode: .plan, phase: .planning),
            event: .modeChanged(.standard, at: start)
        )

        XCTAssertEqual(result.mode, .standard)
        XCTAssertEqual(result.phase, .executing)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testModeChangeDoesNotHideAUserInputRequest() {
        let result = SessionReducer.reduce(
            snapshot(mode: .standard, phase: .waitingForUser),
            event: .modeChanged(.plan, at: start)
        )

        XCTAssertEqual(result.mode, .plan)
        XCTAssertEqual(result.phase, .waitingForUser)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testStartingActivityUsesCurrentModeAndReplacesMatchingActivity() {
        // Same identifier, different kind: the assertion below then shows the entry really was
        // replaced rather than merely still being there.
        let replacement = SessionActivity(id: "shell-1", kind: .tool, startedAt: start)

        for (mode, expectedPhase) in [
            (SessionMode.standard, SessionPhase.executing),
            (.plan, .planning),
        ] {
            var initial = snapshot(mode: mode, phase: .idle)
            initial.activities = [activity(id: replacement.id)]

            let result = SessionReducer.reduce(
                initial,
                event: .activityStarted(replacement, at: start)
            )

            XCTAssertEqual(result.phase, expectedPhase)
            XCTAssertEqual(result.activities, [replacement])
            XCTAssertEqual(result.lastObservedAt, start)
        }
    }

    func testStopKeepsOnlyTheCallsThatOutliveTheirTurn() {
        let shell = SessionActivity(
            id: "shell-1",
            kind: .shell,
            startedAt: start
        )
        let subagent = SessionActivity(
            id: "agent-1",
            kind: .subagent,
            startedAt: start,
            parentID: "main",
            outlivesTurn: true
        )

        var result = SessionReducer.reduce(
            snapshot(),
            event: .turnStarted(mode: .standard, at: start)
        )
        result = SessionReducer.reduce(result, event: .activityStarted(shell, at: start))
        result = SessionReducer.reduce(result, event: .activityStarted(subagent, at: start))

        XCTAssertEqual(result.phase, .executing)
        XCTAssertEqual(result.activities, [shell, subagent])

        result = SessionReducer.reduce(result, event: .turnCompleted(at: start))

        // The shell cannot still be running — its turn is over — so it goes, and only the
        // subagent keeps the session waiting.
        XCTAssertEqual(result.phase, .waitingForChildren)
        XCTAssertEqual(result.activities, [subagent])
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testCompletingTheLastChildFinishesTheSession() {
        let activity = SessionActivity(
            id: "shell-1",
            kind: .shell,
            startedAt: start
        )
        var initial = snapshot(phase: .waitingForChildren)
        initial.activities = [activity]

        let result = SessionReducer.reduce(
            initial,
            event: .activityCompleted(id: activity.id, at: start.addingTimeInterval(1))
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertEqual(result.lastObservedAt, start.addingTimeInterval(1))
    }

    /// The mode does not change the answer: a turn that has ended has ended.
    func testCompletingTheLastChildFinishesAPlanSessionToo() {
        let runningActivity = activity(id: "shell-1")
        var initial = snapshot(mode: .plan, phase: .waitingForChildren)
        initial.activities = [runningActivity]

        let result = SessionReducer.reduce(
            initial,
            event: .activityCompleted(id: runningActivity.id, at: start)
        )

        XCTAssertEqual(result.phase, .completed)
        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testCompletingOneOfSeveralChildrenKeepsWaiting() {
        let first = activity(id: "shell-1")
        let second = activity(id: "shell-2")
        var initial = snapshot(phase: .waitingForChildren)
        initial.activities = [first, second]

        let result = SessionReducer.reduce(
            initial,
            event: .activityCompleted(id: first.id, at: start)
        )

        XCTAssertEqual(result.phase, .waitingForChildren)
        XCTAssertEqual(result.activities, [second])
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testCompletingActivityWhileExecutingDoesNotChangePhase() {
        let runningActivity = activity(id: "shell-1")
        var initial = snapshot(phase: .executing)
        initial.activities = [runningActivity]

        let result = SessionReducer.reduce(
            initial,
            event: .activityCompleted(id: runningActivity.id, at: start)
        )

        XCTAssertEqual(result.phase, .executing)
        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    /// The reported bug, as a test. A refused or interrupted call never reports its own
    /// ending, so before this the session stayed in `waitingForChildren` forever and showed
    /// subagents it never had. `Stop` is what releases it.
    func testStopClearsACallWhoseEndingNeverArrived() {
        let denied = SessionActivity(
            id: "tool-1",
            kind: .subagent,
            startedAt: start
        )
        var initial = snapshot(phase: .executing)
        initial.activities = [denied]

        let result = SessionReducer.reduce(initial, event: .turnCompleted(at: start))

        XCTAssertEqual(result.phase, .completed)
        XCTAssertTrue(result.activities.isEmpty)
    }

    func testUserInputRequestRaisesAttention() {
        let result = SessionReducer.reduce(
            snapshot(),
            event: .userInputRequired(reason: .approval, activityID: nil, agentID: nil, at: start)
        )

        XCTAssertEqual(result.phase, .waitingForUser)
        XCTAssertEqual(result.userInputRequestKind, .approval)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testTurnCompletionWaitsForBackgroundActivities() {
        let background = SessionActivity(
            id: "background-1",
            kind: .backgroundTask,
            startedAt: start,
            outlivesTurn: true
        )
        var initial = snapshot(phase: .executing)
        initial.activities = [background]

        let observedAt = start.addingTimeInterval(1)

        let result = SessionReducer.reduce(
            initial,
            event: .turnCompleted(at: observedAt)
        )

        XCTAssertEqual(result.phase, .waitingForChildren)
        XCTAssertEqual(result.activities, [background])
        XCTAssertEqual(result.lastObservedAt, observedAt)
    }

    /// A new call starting is the main exit from a wait: the agent being asked is paused, so
    /// it issues nothing new until it is answered. This is the main thread's own dialog —
    /// the case Codex also has, since its hooks name no agent — and there the exit is
    /// unchanged. A start by *another* agent is `testOnlyTheAgentThatWasAskedCanEndItsOwnWait`.
    ///
    /// The awaited id is set here to the value a real permission request would have
    /// recorded, so the test would fail if the completion guard were ever extended to cover
    /// starts as well.
    func testStartingActivityResumesAfterPermissionRequest() {
        var waiting = snapshot(phase: .waitingForUser)
        waiting.awaitedActivityID = "bash-1"
        waiting.userInputRequestKind = .approval

        let result = SessionReducer.reduce(waiting, event: .activityStarted(activity(id: "shell-1"), at: start))

        XCTAssertEqual(result.phase, .executing)
        XCTAssertNil(result.userInputRequestKind)
        XCTAssertNil(result.awaitedActivityID)
    }

    /// The signal this widget exists to deliver. A parallel tool finishing says nothing
    /// about a dialog still on screen, and treating it as an answer put the session back to
    /// `working` with the question unanswered.
    func testAnUnrelatedToolFinishingLeavesTheSessionWaiting() {
        var waiting = SessionSnapshot(
            id: "session",
            source: .claude,
            arrivalIndex: 0,
            title: "Session",
            phase: .executing,
            lastObservedAt: start
        )
        waiting = SessionReducer.reduce(
            waiting,
            event: .activityStarted(
                SessionActivity(id: "asked", kind: .tool, startedAt: start),
                at: start
            )
        )
        waiting = SessionReducer.reduce(
            waiting,
            event: .userInputRequired(reason: .selection, activityID: "asked", agentID: nil, at: start)
        )

        let unrelated = SessionReducer.reduce(
            waiting,
            event: .activityCompleted(id: "some-other-bash-call", at: start.addingTimeInterval(1))
        )

        XCTAssertEqual(unrelated.phase, .waitingForUser)
        XCTAssertEqual(unrelated.userInputRequestKind, .selection)

        let answered = SessionReducer.reduce(
            unrelated,
            event: .activityCompleted(id: "asked", at: start.addingTimeInterval(2))
        )

        XCTAssertEqual(answered.phase, .executing, "the awaited call finished, so the wait is over")
        XCTAssertNil(answered.awaitedActivityID)
    }

    /// The stranding this guards against: the app misses one `PostToolUse` — hooks are
    /// fail-open, so a missed event is a designed-for condition — and without an exit the
    /// session sat at an urgent blinking lamp forever, with nothing to sweep it.
    func testAWaitStillEndsWhenTheAwaitedCompletionNeverArrives() {
        var waiting = SessionSnapshot(
            id: "session",
            source: .claude,
            arrivalIndex: 0,
            title: "Session",
            phase: .waitingForUser,
            userInputRequestKind: .approval,
            awaitedActivityID: "never-completes",
            lastObservedAt: start
        )
        waiting.activities = [
            SessionActivity(id: "never-completes", kind: .shell, startedAt: start)
        ]

        let next = SessionReducer.reduce(
            waiting,
            event: .activityStarted(
                SessionActivity(id: "the-next-call", kind: .tool, startedAt: start),
                at: start.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(next.phase, .executing, "a new call can only have been issued after an answer")
        XCTAssertNil(next.awaitedActivityID)
    }

    /// A turn ending is the other exit, for a wait that was answered with nothing to run.
    func testATurnEndingClearsAWaitAndItsAwaitedCall() {
        var waiting = snapshot(phase: .waitingForUser)
        waiting.awaitedActivityID = "bash-1"
        waiting.userInputRequestKind = .approval

        let next = SessionReducer.reduce(waiting, event: .turnCompleted(at: start))

        XCTAssertEqual(next.phase, .completed)
        XCTAssertNil(next.awaitedActivityID)
    }

    /// A permission request names no tool of its own, so the call it follows is the one being
    /// waited on.
    func testAPermissionRequestWaitsOnTheCallItFollowed() {
        var session = SessionSnapshot(
            id: "session",
            source: .claude,
            arrivalIndex: 0,
            title: "Session",
            phase: .executing,
            lastObservedAt: start
        )
        session = SessionReducer.reduce(
            session,
            event: .activityStarted(
                SessionActivity(id: "bash-1", kind: .shell, startedAt: start),
                at: start
            )
        )

        let asked = SessionReducer.reduce(
            session,
            event: .userInputRequired(reason: .approval, activityID: nil, agentID: nil, at: start)
        )

        XCTAssertEqual(asked.awaitedActivityID, "bash-1")
    }

    /// `AskUserQuestion` records its own tool id, so the completion that answers it is that
    /// same id. Set here rather than left at `nil`, or the test would exercise the fallback
    /// instead of the path the normalizer actually produces.
    func testToolCompletionResumesAfterAnAskUserQuestion() {
        var waiting = snapshot(phase: .waitingForUser)
        waiting.awaitedActivityID = "id_question"
        waiting.userInputRequestKind = .selection

        let result = SessionReducer.reduce(waiting, event: .activityCompleted(id: "id_question", at: start))

        XCTAssertEqual(result.phase, .executing)
        XCTAssertNil(result.awaitedActivityID)
    }

    func testFailureRaisesErrorAttention() {
        let result = SessionReducer.reduce(snapshot(), event: .failed(at: start))

        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testDisconnectMarksSessionWithoutDiscardingActivities() {
        let runningActivity = activity(id: "shell-1")
        var initial = snapshot(phase: .executing)
        initial.activities = [runningActivity]

        let result = SessionReducer.reduce(initial, event: .disconnected(at: start))

        XCTAssertEqual(result.phase, .disconnected)
        XCTAssertEqual(result.activities, [runningActivity])
        XCTAssertEqual(result.lastObservedAt, start)
    }

    func testSessionCloseClearsActivitiesAndDoesNotPretendTheTurnCompleted() {
        let runningActivity = activity(id: "shell-1")
        var initial = snapshot(phase: .executing)
        initial.activities = [runningActivity]

        let result = SessionReducer.reduce(initial, event: .sessionClosed(at: start))

        XCTAssertEqual(result.phase, .sessionClosed)
        XCTAssertTrue(result.activities.isEmpty)
        XCTAssertEqual(result.lastObservedAt, start)
    }

    // MARK: - Facts that only the transcript reports

    /// The case `activityCompleted` deliberately does not handle. A background command is
    /// answered with a handle in about five seconds while it runs on, so its own call
    /// returning must not close it — but the agent's task notification says the work itself
    /// is over, and that must.
    func testWorkEndedClosesBackgroundWorkThatItsOwnCallCannot() {
        var session = snapshot(phase: .executing)
        session.activities = [
            SessionActivity(
                id: "detached",
                kind: .backgroundTask,
                startedAt: start,
                outlivesTurn: true,
                outlivesItsCall: true
            )
        ]

        let afterItsCall = SessionReducer.reduce(session, event: .activityCompleted(id: "detached", at: start))
        XCTAssertEqual(
            afterItsCall.activities.map(\.id),
            ["detached"],
            "the call handed back a handle; the command is still running"
        )

        let afterTheWork = SessionReducer.reduce(afterItsCall, event: .workEnded(id: "detached", at: start))
        XCTAssertTrue(afterTheWork.activities.isEmpty, "the agent reported the work itself ended")
    }

    /// Measured with a control: an interrupted turn delivers no hook at all, while the same
    /// session delivered `Stop` twice for turns that ended normally. Until the transcript was
    /// read, such a session went on claiming to be working with no event that could stop it.
    func testAnInterruptedTurnGoesToRestRatherThanClaimingCompletion() {
        var session = snapshot(phase: .executing)
        session.activities = [
            SessionActivity(id: "shell", kind: .shell, startedAt: start),
            SessionActivity(id: "agent", kind: .subagent, startedAt: start, outlivesTurn: true),
        ]

        let result = SessionReducer.reduce(session, event: .turnInterrupted(at: start))

        XCTAssertEqual(result.phase, .idle, "nothing completed, so `completed` would state the opposite")
        XCTAssertTrue(result.activities.isEmpty, "the interruption is aimed at the turn, subagent included")
        XCTAssertEqual(result.lastObservedAt, start)
    }

    /// The difference from an interruption: `Stop` settles only the turn, and a subagent it
    /// spawned keeps working and reports its own end.
    func testACompletedTurnStillKeepsASubagentThatAnInterruptionWouldDrop() {
        var session = snapshot(phase: .executing)
        session.activities = [SessionActivity(id: "agent", kind: .subagent, startedAt: start, outlivesTurn: true)]

        let result = SessionReducer.reduce(session, event: .turnCompleted(at: start))

        XCTAssertEqual(result.activities.map(\.id), ["agent"])
        XCTAssertEqual(result.phase, .waitingForChildren)
    }

    // MARK: - Whether the quiet is accounted for

    func testOnlyABusySessionHasQuietWorthLookingInto() {
        for phase in [SessionPhase.idle, .waitingForUser, .completed, .failed, .disconnected, .sessionClosed] {
            XCTAssertTrue(SessionSilence.isExpected(snapshot(phase: phase)), "\(phase) says why it is quiet")
        }
        for phase in [SessionPhase.planning, .executing, .waitingForChildren] {
            XCTAssertFalse(SessionSilence.isExpected(snapshot(phase: phase)), "\(phase) claims to be busy")
        }
    }

    // MARK: - What the transcript may and may not do

    /// The transcript is a late witness: it is read seconds after the fact, and by then the
    /// session may have moved on. So a call it reports is added to the list and nothing else
    /// is touched — the phase and the awaited call both belong to the hooks,
    /// which is what `AGENTS.md` means by lifecycle facts being deterministic.
    ///
    /// The case that makes this concrete: an advisor call starts, a permission prompt appears
    /// two seconds later, and the reader arrives at both a poll afterwards. Applying the call
    /// through `activityStarted` would clear the wait and put out the lamp asking for an
    /// answer.
    func testACallObservedInTheTranscriptLeavesAWaitingSessionWaiting() {
        var previous = snapshot(mode: .standard, phase: .waitingForUser)
        previous.userInputRequestKind = .approval
        previous.awaitedActivityID = "the-call-being-approved"

        let result = SessionReducer.reduce(
            previous,
            event: .activityObserved(advisorActivity(id: "advisor-1"), at: start)
        )

        XCTAssertEqual(result.activities.map(\.id), ["advisor-1"])
        XCTAssertEqual(result.phase, .waitingForUser, "the transcript does not end a wait")
        XCTAssertEqual(result.userInputRequestKind, .approval)
        XCTAssertEqual(result.awaitedActivityID, "the-call-being-approved")
        XCTAssertEqual(result.lastObservedAt, start, "reading the record is still proof of life")
    }

    /// The only reason `activityFailed` exists apart from `activityCompleted` — and nothing
    /// held it in place. Both cases removed a call by id, but completion spares one that
    /// outlives its own call, because a background shell hands back a handle in about five
    /// seconds and runs on. A failure or a denial started no such work, so nothing of it can
    /// outlive it. Copy the completion's guard onto the failure and every other test here
    /// stays green, while a denied background `Bash` pins that row's count with no event
    /// left that could ever release it.
    func testAFailedBackgroundCallIsClearedThoughACompletedOneIsNot() {
        var running = snapshot(mode: .standard, phase: .executing)
        running.activities = [backgroundActivity(id: "bash-1")]

        let completed = SessionReducer.reduce(
            running,
            event: .activityCompleted(id: "bash-1", at: start)
        )
        XCTAssertEqual(
            completed.activities.map(\.id),
            ["bash-1"],
            "the call handed back a handle; the command it started is still running"
        )

        let failed = SessionReducer.reduce(
            running,
            event: .activityFailed(id: "bash-1", at: start)
        )
        XCTAssertTrue(failed.activities.isEmpty, "a call that was refused started nothing to outlive it")
    }

    /// Measured on 2.1.272: every hook fired from inside a subagent carries `agent_id`, and
    /// the main thread's hooks carry none. So a dialog has an owner, and only its owner's
    /// events say anything about it.
    ///
    /// The sequence is a real one, from the evening the row was wrong: a subagent asked for
    /// permission at 19:48:09, a second subagent started a call one second later, the main
    /// turn ended at 19:58:54 and was given a new prompt — and the dialog was still on screen
    /// through all of it. Every one of those three used to end the wait.
    func testOnlyTheAgentThatWasAskedCanEndItsOwnWait() {
        var session = SessionSnapshot(
            id: "session",
            source: .claude,
            arrivalIndex: 0,
            title: "Session",
            phase: .executing,
            lastObservedAt: start
        )
        session = SessionReducer.reduce(
            session,
            event: .activityStarted(subagent(id: "reviewer-a"), at: start)
        )
        session = SessionReducer.reduce(
            session,
            event: .activityStarted(call(id: "a-bash", owner: "reviewer-a"), at: start.addingTimeInterval(1))
        )

        let asked = SessionReducer.reduce(
            session,
            event: .userInputRequired(
                reason: .approval,
                activityID: nil,
                agentID: "reviewer-a",
                at: start.addingTimeInterval(2)
            )
        )

        XCTAssertEqual(asked.phase, .waitingForUser)
        XCTAssertEqual(asked.awaitedAgentID, "reviewer-a")
        XCTAssertEqual(
            asked.awaitedActivityID,
            "a-bash",
            "the call being asked about is the asking agent's own last one, not the session's"
        )

        let elsewhere = SessionReducer.reduce(
            asked,
            event: .activityStarted(call(id: "b-bash", owner: "reviewer-b"), at: start.addingTimeInterval(3))
        )

        XCTAssertEqual(elsewhere.phase, .waitingForUser, "another subagent works on while this one is blocked")

        let mainTurnEnded = SessionReducer.reduce(elsewhere, event: .turnCompleted(at: start.addingTimeInterval(4)))

        XCTAssertEqual(mainTurnEnded.phase, .waitingForUser, "the main turn ending is not an answer to a child")

        let nextPrompt = SessionReducer.reduce(
            mainTurnEnded,
            event: .turnStarted(mode: .standard, at: start.addingTimeInterval(5))
        )

        XCTAssertEqual(nextPrompt.phase, .waitingForUser, "a person can type while the dialog is still up")

        let released = SessionReducer.reduce(
            nextPrompt,
            event: .activityCompleted(id: "reviewer-a", at: start.addingTimeInterval(6))
        )

        XCTAssertEqual(released.phase, .executing, "`SubagentStop` for the owner ends what nothing else could")
        XCTAssertNil(released.awaitedAgentID)
        XCTAssertNil(released.awaitedActivityID)
    }

    /// A consequence of the owner rule worth pinning, because nothing else asserts it: a
    /// subagent's call arriving after the parent's `Stop` no longer drags the row back into
    /// `executing`. The turn really has ended — the work is the child's, and
    /// `waitingForChildren` is what says so.
    ///
    /// The degraded case, stated rather than fixed: if that child's `SubagentStart` was
    /// missed, a `completed` row now stays `completed` where it used to flip to `executing`.
    /// Both readings are wrong about something, and this one is wrong more quietly.
    func testASubagentsCallAfterTheTurnEndedLeavesTheRowWaitingForItsChildren() {
        var session = snapshot(mode: .standard, phase: .executing)
        session = SessionReducer.reduce(session, event: .activityStarted(subagent(id: "child"), at: start))
        session = SessionReducer.reduce(session, event: .turnCompleted(at: start.addingTimeInterval(1)))
        XCTAssertEqual(session.phase, .waitingForChildren)

        let childWorks = SessionReducer.reduce(
            session,
            event: .activityStarted(call(id: "child-bash", owner: "child"), at: start.addingTimeInterval(2))
        )

        XCTAssertEqual(childWorks.phase, .waitingForChildren, "the parent's turn is over; this is the child's work")
    }

    private func subagent(id: String) -> SessionActivity {
        SessionActivity(id: id, kind: .subagent, startedAt: start, outlivesTurn: true)
    }

    private func call(id: String, owner: String?) -> SessionActivity {
        SessionActivity(id: id, kind: .shell, startedAt: start, parentID: owner)
    }

    private func backgroundActivity(id: String) -> SessionActivity {
        SessionActivity(
            id: id,
            kind: .backgroundTask,
            startedAt: start,
            outlivesTurn: true,
            outlivesItsCall: true
        )
    }

    private func advisorActivity(id: String) -> SessionActivity {
        SessionActivity(id: id, kind: .advisor, startedAt: start)
    }

    private func snapshot(mode: SessionMode = .unknown, phase: SessionPhase = .idle) -> SessionSnapshot {
        testSession(source: .codex, mode: mode, phase: phase, lastObservedAt: start.addingTimeInterval(-1))
    }

    private func activity(id: String) -> SessionActivity {
        SessionActivity(id: id, kind: .shell, startedAt: start)
    }
}
