import Foundation

public enum SessionEvent: Equatable, Sendable {
    case sessionStarted(mode: SessionMode?, at: Date)
    case turnStarted(mode: SessionMode, at: Date)
    case modeChanged(SessionMode, at: Date)
    case activityStarted(SessionActivity, at: Date)
    /// A call the transcript reported after the fact.
    ///
    /// Deliberately narrower than `activityStarted`: it adds the call to the list and moves
    /// the age, and touches nothing else. The transcript is read seconds late, and by then the
    /// session may have gone on to wait for a person — so letting it set the phase would undo
    /// a newer, better-sourced fact. Lifecycle belongs to the hooks.
    ///
    /// The age it sets can be *older* than what the session already knows, for the same
    /// reason. Holding it forward is the caller's job — `SessionStateEngine.apply` clamps
    /// every transcript fact against the age it had — and this reducer, like every case
    /// beside it, simply states what the record said.
    case activityObserved(SessionActivity, at: Date)
    case activityCompleted(id: String, at: Date)
    /// Work that outlived its own call has really ended — the fact behind
    /// `TranscriptFact.workEnded`, and the only observation of that moment there is.
    case workEnded(id: String, at: Date)
    case activityFailed(id: String, at: Date)
    case userInputRequired(reason: UserInputRequestKind, activityID: String?, at: Date)
    case turnCompleted(at: Date)
    /// A person stopped the turn. Distinct from `turnCompleted` because nothing completed.
    case turnInterrupted(at: Date)
    case failed(at: Date)
    case disconnected(at: Date)
    case sessionClosed(at: Date)
}

public enum SessionReducer {
    public static func reduce(
        _ snapshot: SessionSnapshot,
        event: SessionEvent
    ) -> SessionSnapshot {
        var next = snapshot

        switch event {
        case let .sessionStarted(mode, observedAt):
            next.mode = mode ?? .unknown
            next.phase = .idle
            next.userInputRequestKind = nil
            next.awaitedActivityID = nil
            next.activities = []
            next.lastObservedAt = observedAt

        case let .turnStarted(mode, observedAt):
            next.mode = mode
            // A new prompt ends the previous turn whatever became of it, so the same sweep as
            // `turnCompleted` runs here — and for the same reason, with the same exception for
            // a subagent that is still working.
            //
            // Not a duplicate of that sweep but the other half of it: `Stop` is not delivered
            // for every turn. Measured in this project's own event log, 8 turns started and 4
            // completed in 39 minutes, one session starting four turns in a row without a
            // single `Stop` between them — an interrupted turn reports nothing, and hooks are
            // fail-open besides. Without this line a call whose ending never arrived was
            // counted through every following turn until some later `Stop` happened to fire.
            //
            // Background work is swept here and not by `Stop`, which is the difference
            // between the two sweeps. A background shell keeps running after the turn that
            // started it ends, and nothing reports its real end — but the notification of
            // that end is itself what starts the next turn. Measured in this project's own
            // event log: three background tasks ended at 00:03:40, 00:12:17 and 23:56:06,
            // and each session began a turn within a second of that. So the start of the
            // next turn is the latest moment the work can still honestly be called running.
            // It is not proof — a person typing while the task runs starts a turn too, and
            // drops the row early — but that errs towards claiming too little rather than
            // accumulating work that finished long ago.
            next.activities.removeAll { !$0.outlivesTurn || $0.outlivesItsCall }
            // `unknown` is not `standard`. A turn whose mode nobody stated is still work in
            // progress, and calling it planning would be a claim; `executing` says only what
            // is known — a turn is running.
            next.phase = mode == .plan ? .planning : .executing
            next.userInputRequestKind = nil
            next.awaitedActivityID = nil
            next.lastObservedAt = observedAt

        case let .modeChanged(mode, observedAt):
            next.mode = mode
            if next.phase == .planning || next.phase == .executing {
                next.phase = mode == .plan ? .planning : .executing
            }
            next.lastObservedAt = observedAt

        case let .activityStarted(activity, observedAt):
            next.activities.removeAll { $0.id == activity.id }
            next.activities.append(activity)
            // A *new* call starting does end a wait, and it is the exit that matters most:
            // the turn is paused while a person is being asked, so nothing new is issued
            // until they answer. Calls already in flight keep completing — that is why a
            // completion is checked against the awaited id below and a start is not.
            //
            // Without this exit a session whose awaited completion never arrived — the app
            // was down for a moment, and hooks are fail-open by design — stayed at an urgent
            // blinking lamp forever, with nothing to sweep it and no way to dismiss it.
            next.phase = next.mode == .plan ? .planning : .executing
            next.userInputRequestKind = nil
            next.awaitedActivityID = nil
            next.lastObservedAt = observedAt

        case let .activityObserved(activity, observedAt):
            // Replaced rather than duplicated, the same way `activityStarted` does it: the
            // transcript can report the same call twice when a read is re-synchronised.
            next.activities.removeAll { $0.id == activity.id }
            next.activities.append(activity)
            next.lastObservedAt = observedAt

        case let .activityCompleted(id, observedAt):
            // A call reporting success does not always mean its work is over. A background
            // shell hands back a handle in about five seconds and runs on; nothing reports
            // its real end, so only the end of the turn clears it.
            next.activities.removeAll { $0.id == id && !$0.outlivesItsCall }
            endWait(&next, forActivity: id, at: observedAt)
            next.lastObservedAt = observedAt

        case let .workEnded(id, observedAt):
            // The one case that closes background work. `activityCompleted` must not: the
            // call it reports hands back a handle in about five seconds while the command
            // runs on, so treating that as the end would close the work as it started.
            // Here the agent has said the work itself finished or was killed.
            next.activities.removeAll { $0.id == id }
            endWait(&next, forActivity: id, at: observedAt)
            next.lastObservedAt = observedAt

        case let .activityFailed(id, observedAt):
            // A call that failed or was refused started no work at all, so nothing of it can
            // outlive it — which is why this is a separate event and not a completion.
            next.activities.removeAll { $0.id == id }
            endWait(&next, forActivity: id, at: observedAt)
            next.lastObservedAt = observedAt

        case let .userInputRequired(reason, activityID, observedAt):
            next.phase = .waitingForUser
            next.userInputRequestKind = reason
            // A permission request names no tool of its own, but it always follows the start
            // of the call it is asking about — so the most recent activity is the one being
            // waited on. An inference, but from event order, not from any model's words.
            next.awaitedActivityID = activityID ?? next.activities.last?.id
            next.lastObservedAt = observedAt

        case let .turnCompleted(observedAt):
            // `Stop` settles the turn: whatever it issued is over. Only a subagent can still
            // be running, so every other open call is dropped rather than kept as a child.
            //
            // Without this, a call whose ending never arrived pinned the session in
            // `waitingForChildren` with no event that could ever release it. Nothing reports
            // the ending of an interrupted call, and a denied one reports `PermissionDenied`,
            // not `PostToolUse` — so the session showed subagents it never had and claimed to
            // be waiting for subtasks while it was in fact waiting for a person.
            next.activities.removeAll { !$0.outlivesTurn }
            next.phase = next.activities.isEmpty ? .completed : .waitingForChildren
            next.userInputRequestKind = nil
            next.awaitedActivityID = nil
            next.lastObservedAt = observedAt

        case let .turnInterrupted(observedAt):
            // Everything the turn issued stops with it, a subagent included: the interruption
            // is aimed at the whole turn, not at one call. That is the difference from
            // `turnCompleted`, where a subagent goes on working and reports its own end.
            //
            // `idle`, not `completed`: nothing completed. A green "completed" lamp on a turn
            // a person stopped states the opposite of what happened, while `idle` says what
            // is true — the session is at rest with nothing running, exactly as it is between
            // a `SessionStart` and the first prompt.
            next.activities.removeAll()
            next.phase = .idle
            next.userInputRequestKind = nil
            next.awaitedActivityID = nil
            next.lastObservedAt = observedAt

        case let .failed(observedAt):
            next.phase = .failed
            next.awaitedActivityID = nil
            next.lastObservedAt = observedAt

        case let .disconnected(observedAt):
            next.phase = .disconnected
            next.awaitedActivityID = nil
            next.lastObservedAt = observedAt

        case let .sessionClosed(observedAt):
            next.phase = .sessionClosed
            next.userInputRequestKind = nil
            next.awaitedActivityID = nil
            next.activities = []
            next.lastObservedAt = observedAt
        }

        // A complaint about watching a session expires the moment that session stops
        // claiming to work. Nothing more can be missed, so a warning left standing would be
        // a warning about nothing — and the wording makes that plain: "says it is working,
        // nothing is running, and nothing has been heard" beside a lamp reading `completed`
        // states the opposite of what the row says.
        //
        // Here rather than in the reader that raised it, because every way out of a working
        // phase runs through this function, and the reader can be switched off between the
        // fault and the phase change that ends it.
        if SessionSilence.isExpected(next) {
            next.monitoringFault = nil
        }

        return next
    }

    /// What the end of one activity means for a session that was waiting.
    ///
    /// Only the call the session is actually waiting on ends the wait. With no awaited call
    /// recorded there is nothing to compare against, and any ending has to be taken as the
    /// answer.
    static func activityEndsWait(awaitedActivityID: String?, endingActivityID: String) -> Bool {
        awaitedActivityID == nil || awaitedActivityID == endingActivityID
    }

    private static func endWait(_ next: inout SessionSnapshot, forActivity id: String, at: Date) {
        if next.phase == .waitingForUser,
            // Without an identity, a late ending from a previous turn cannot answer this
            // dialog. Named calls still close out of order by their own identity.
            (next.awaitedActivityID != nil || at >= next.lastObservedAt),
            activityEndsWait(awaitedActivityID: next.awaitedActivityID, endingActivityID: id)
        {
            next.phase = next.mode == .plan ? .planning : .executing
            next.userInputRequestKind = nil
            next.awaitedActivityID = nil
        } else if next.phase == .waitingForChildren && next.activities.isEmpty {
            // The turn ended before this child did — that is the only way into
            // `waitingForChildren` — so the session is finished, not back at work.
            next.phase = .completed
        }
    }
}
