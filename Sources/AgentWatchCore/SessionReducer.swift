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
    /// Somebody is being asked something. `agentID` names which agent was asked — `nil` for
    /// the session's main thread — and `activityID` the call, when the hook gave one.
    case userInputRequired(
        reason: UserInputRequestKind,
        activityID: String?,
        agentID: String?,
        at: Date
    )
    /// The dialog the session was waiting on is gone — answered, or dismissed.
    ///
    /// Deliberately not "the person said yes": what is observed is that nothing is being
    /// asked any more, and the difference between an answer and an Esc is not in the record.
    /// Either way the session is no longer waiting for anybody, which is the whole of what
    /// the lamp claims.
    case userInputResolved(at: Date)
    case turnCompleted(at: Date)
    /// What the session still has running, as the hook that ended the turn listed it.
    ///
    /// Its own event rather than a second value on `turnCompleted`, because it is a second
    /// fact: the turn ending is one observation and what it left behind is another, and a
    /// `Stop` from a sender too old to report the list must still end the turn. Every list
    /// replaces the one before it — Claude Code sends the live set each time, not a change.
    case backgroundWorkReported([BackgroundWorkKind], at: Date)
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
            next.clearAwaited()
            next.activities = []
            // Nothing reported rather than nothing running — see `turnStarted` below, where
            // the difference between the two is spelled out.
            next.backgroundWork = nil
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
            // And the list of what the last turn left running goes with them, for the reason
            // just given: the end of background work is itself what starts the next turn.
            // A person typing while it runs clears the list early here too, and the next
            // `Stop` puts back whatever is still going.
            //
            // Back to nothing reported, not to an empty list. The two are different claims —
            // `nil` says no `Stop` has spoken since, `[]` says one spoke and said there was
            // nothing — and the difference is what a row draws: with nothing reported it
            // falls back to the background calls this app counted for itself, and an empty
            // list overrules them. Emptied here, a shell started in this very turn was drawn
            // by nobody until the turn ended.
            next.backgroundWork = nil
            // `unknown` is not `standard`. A turn whose mode nobody stated is still work in
            // progress, and calling it planning would be a claim; `executing` says only what
            // is known — a turn is running.
            // Only the main thread's own dialog. A person can type a new prompt while a
            // subagent's permission dialog is still on screen — measured that evening, at
            // 19:56 — and doing so answers nothing. A second subagent's dialog is no more
            // answered than the first, which is why what is left decides the phase.
            next.endDialogs { $0.agentID == nil }
            if !next.isAwaitingAnswer {
                next.phase = mode == .plan ? .planning : .executing
            }
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
            // the agent being asked is paused, so it issues nothing new until it is
            // answered. Calls already in flight keep completing — that is why a completion
            // is checked against the awaited id below and a start is not.
            //
            // Without this exit a session whose awaited completion never arrived — the app
            // was down for a moment, and hooks are fail-open by design — stayed at an urgent
            // blinking lamp forever, with nothing to sweep it and no way to dismiss it.
            //
            // *The agent being asked*, not the session: a second subagent goes on working
            // while the first one waits, and its calls say nothing about a dialog it never
            // saw. That is what put the row back to `working` one second after the dialog
            // opened. With two agents asked at once it ends one dialog and leaves the other,
            // so the session goes on waiting until the list is empty.
            let wasAwaiting = next.isAwaitingAnswer
            next.endDialogs { $0.agentID == activity.parentID }
            // The second half of the condition is the ordinary case, with nothing asked at
            // all: a call from the main thread means the session is working. A subagent's
            // does not, since it says nothing about what the session as a whole is doing.
            if !next.isAwaitingAnswer, wasAwaiting || activity.parentID == nil {
                next.phase = next.mode == .plan ? .planning : .executing
            }
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

        case let .userInputRequired(reason, activityID, agentID, observedAt):
            next.phase = .waitingForUser
            // A permission request names no tool of its own — measured on 2.1.272, it is the
            // one tool hook with no `tool_use_id` — but it always follows the start of the
            // call it is asking about, in that same agent. So the asking agent's most recent
            // call is the one being waited on. An inference, but from event order, not from
            // any model's words.
            //
            // Filtered by owner, because the session's own last call belongs to whichever
            // agent happened to speak last, which on a session running several subagents is
            // almost never the one being asked.
            next.awaitAnswer(
                to: AwaitedDialog(
                    agentID: agentID,
                    activityID: activityID ?? next.activities.last { $0.parentID == agentID }?.id,
                    kind: reason
                )
            )
            next.lastObservedAt = observedAt

        case let .userInputResolved(observedAt):
            // Every dialog at once, and this is the one exit that may: the observation
            // behind it is the session's own record saying nothing is being asked of
            // anybody (ADR-0010), not one call or one agent reporting for itself.
            if next.phase == .waitingForUser {
                next.phase = next.mode == .plan ? .planning : .executing
                next.clearAwaited()
            }
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
            // A subagent's dialog outlives the turn that spawned it, and `Stop` is the main
            // thread's own event — it answers nothing that was asked of a child. Its wait is
            // released by that child's own `SubagentStop`, by the ending of the call being
            // asked about, or by Claude Code's session record (ADR-0010).
            next.endDialogs { $0.agentID == nil }
            if !next.isAwaitingAnswer {
                next.phase = next.activities.isEmpty ? .completed : .waitingForChildren
            }
            next.lastObservedAt = observedAt

        case let .backgroundWorkReported(kinds, observedAt):
            next.backgroundWork = kinds
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
            next.clearAwaited()
            next.lastObservedAt = observedAt

        case let .failed(observedAt):
            next.phase = .failed
            next.clearAwaited()
            next.lastObservedAt = observedAt

        case let .disconnected(observedAt):
            next.phase = .disconnected
            next.clearAwaited()
            next.lastObservedAt = observedAt

        case let .sessionClosed(observedAt):
            next.phase = .sessionClosed
            next.clearAwaited()
            next.activities = []
            next.backgroundWork = nil
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

    /// What the end of one activity means for one dialog.
    ///
    /// Only the call the dialog is about answers it. With no call recorded there is nothing
    /// to compare against, and any ending has to be taken as the answer.
    ///
    /// That last rule belongs to the main thread alone, and the dialog's owner is what says
    /// so. It was written when one agent's endings were the only ones that could arrive; on
    /// a session running subagents it hands the answer to whichever other subagent finished
    /// next — the very bug the owner exists to stop, on the path a missed `PreToolUse` leads
    /// to. A subagent's dialog with no known call is released by its own next call or by its
    /// own end instead, both of which name it.
    static func dialogEnds(_ dialog: AwaitedDialog, atActivityID endingActivityID: String) -> Bool {
        if let activityID = dialog.activityID {
            return activityID == endingActivityID
        }
        return dialog.agentID == nil
    }

    private static func endWait(_ next: inout SessionSnapshot, forActivity id: String, at: Date) {
        guard next.phase == .waitingForUser else {
            if next.phase == .waitingForChildren && next.activities.isEmpty {
                // The turn ended before this child did — that is the only way into
                // `waitingForChildren` — so the session is finished, not back at work.
                next.phase = .completed
            }
            return
        }
        // Read before the list is touched: a closure that mutates `next` may not read it.
        let lastObservedAt = next.lastObservedAt
        next.endDialogs { dialog in
            // The asked agent itself ending — `SubagentStop` — releases its dialog whatever
            // became of the call. It is the only release left for a subagent whose dialog
            // was dismissed rather than answered, now that the main thread's own events no
            // longer speak for it.
            if dialog.agentID == id {
                return true
            }
            // Without an identity, a late ending from a previous turn cannot answer this
            // dialog. Named calls still close out of order by their own identity.
            guard dialog.activityID != nil || at >= lastObservedAt else {
                return false
            }
            return dialogEnds(dialog, atActivityID: id)
        }
        if !next.isAwaitingAnswer {
            next.phase = next.mode == .plan ? .planning : .executing
        }
    }
}

extension SessionSnapshot {
    /// Records a question and leaves the row saying what it is.
    ///
    /// A second question from the same owner replaces the first rather than joining it: an
    /// agent is stopped until it is answered, so it can only be asked one thing at a time,
    /// and a repeat is the same dialog restated.
    mutating func awaitAnswer(to dialog: AwaitedDialog) {
        var dialogs = unansweredDialogs
        dialogs.removeAll { $0.agentID == dialog.agentID }
        dialogs.append(dialog)
        setAwaitedDialogs(dialogs)
    }

    /// Forgets every dialog `isAnswered` names, and leaves the rest.
    ///
    /// The one way out of a wait, so that no exit can end somebody else's dialog: each rule
    /// says which dialogs it speaks for, and what is left decides the phase.
    mutating func endDialogs(where isAnswered: (AwaitedDialog) -> Bool) {
        setAwaitedDialogs(unansweredDialogs.filter { !isAnswered($0) })
    }

    /// Forgets every dialog at once: nobody is being waited for any more.
    public mutating func clearAwaited() {
        setAwaitedDialogs([])
    }

    /// The single place the list and the row's summary of it change together. Also how a
    /// wait comes back from the session memory, which brings its dialogs whole.
    ///
    /// The row names one kind, and it is the oldest unanswered question's — the one that
    /// has been waiting longest. Kept beside the list rather than derived at the point of
    /// drawing, because an answer to one dialog has to change it: a dismissed approval
    /// leaving an unanswered choice behind must not go on reading "approval needed".
    public mutating func setAwaitedDialogs(_ dialogs: [AwaitedDialog]) {
        awaitedDialogs = dialogs
        userInputRequestKind = dialogs.first?.kind
    }
}
