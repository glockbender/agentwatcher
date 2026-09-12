import Foundation

public struct SessionStateEngine: Sendable {
    public private(set) var snapshots: [String: SessionSnapshot] = [:]
    public private(set) var usageLimitsBySource: [AgentSource: AgentUsageLimits] = [:]
    /// Only ever moves forward. A removed session's index is deliberately left unused, so a
    /// session that appears later joins at the end of the list instead of taking the place
    /// of the one that left.
    private var nextArrivalIndex = 0
    /// The place a row built from a process leaves behind for the session that turned out to
    /// own it. See `claimDiscoveredRow`.
    ///
    /// It cannot grow: `reconcileDiscoveredProcesses` never builds a row for a process some
    /// session already claims, so the only way to reserve a place is for a session that does
    /// not exist yet — and the next `ingest` for that process spends it.
    private var arrivalIndexLeftByProcess: [Int32: Int] = [:]
    /// Waits restored sessions were remembered in, held back until each session's own file
    /// can say whether they still hold. See `restore` and `confirmRememberedWait`.
    private var rememberedWaits: [String: SessionHistory.RememberedWait] = [:]

    public init() {}

    @discardableResult
    public mutating func ingest(_ event: EventEnvelope) throws -> SessionSnapshot {
        guard event.schemaVersion == EventEnvelope.currentSchemaVersion else {
            throw EventIngestionError.unsupportedSchemaVersion(event.schemaVersion)
        }

        let snapshotID = SessionSnapshot.id(source: event.source, sessionLabel: event.sessionID)
        // The session is speaking for itself, so the memory of what it was waiting for has
        // nothing left to add — whatever the transcript is about to say about it is older
        // than this.
        rememberedWaits.removeValue(forKey: snapshotID)
        var snapshot: SessionSnapshot
        if let known = snapshots[snapshotID] {
            snapshot = known
            // A row that was found by its process and is now speaking for itself stops being
            // a row found by its process. Everything the row had is kept — its place in the
            // list, and whatever its transcript already told us — but this is the moment it
            // becomes a session the file remembers: `SessionHistory.records` writes down no
            // row that is only a process.
            snapshot.discoveredProcess = nil
            // The place a claimed row left behind is spent here too, by dropping it: this
            // session already has a place of its own and moving it would be the shuffling
            // the index exists to stop. Only the `else` below used to spend it, and one case
            // never reaches that branch — `claude --resume` keeps the session's identifier
            // and gives it a new process — so the reservation outlived its process and was
            // handed to whatever session next landed on that number, at an index a live row
            // may already hold.
            if let agentProcessID = event.agentProcessID {
                arrivalIndexLeftByProcess.removeValue(forKey: agentProcessID)
            }
        } else {
            // A session whose process already had a row of its own takes that row's place
            // rather than joining at the end of the list. Without it the row a person was
            // looking at would vanish from the middle of the widget and reappear at the
            // bottom the moment the session finally said something.
            let leftBehind = event.agentProcessID.flatMap { arrivalIndexLeftByProcess.removeValue(forKey: $0) }
            snapshot = SessionSnapshot(
                id: snapshotID,
                source: event.source,
                arrivalIndex: leftBehind ?? nextArrivalIndex,
                lastObservedAt: event.observedAt
            )
            if leftBehind == nil {
                nextArrivalIndex += 1
            }
        }

        if let agentProcessID = event.agentProcessID {
            snapshot.agentProcessID = agentProcessID
        }
        if let clientKind = event.clientKind {
            snapshot.clientKind = clientKind
        }
        if let description = event.description {
            snapshot = Self.merged(snapshot, with: description)
        }
        if let usageLimits = event.usageLimits {
            usageLimitsBySource[usageLimits.source] = usageLimits
        }

        // Closed is terminal, as the state diagram in `docs/architecture.md` §7 says: no edge
        // leaves it. Events do arrive out of order — the protocol is asked to survive that —
        // and a `Stop` landing after a `SessionEnd` used to put the session back to work.
        // What the late event still carries about the session is merged above; only its
        // lifecycle meaning is dropped.
        // `sessionStarted` is the one way back: the same identifier really is reused when a
        // session is cleared and started again, and that is a new session's first event, not
        // a late one from the old. A second `sessionEnded` is dropped with the rest, so a
        // repeated death signal cannot restart the retention clock.
        guard snapshot.phase != .sessionClosed || event.kind == .sessionStarted else {
            snapshots[snapshotID] = snapshot
            return snapshot
        }

        let previouslyObservedAt = snapshot.lastObservedAt
        if let mode = event.mode {
            snapshot = SessionReducer.reduce(snapshot, event: .modeChanged(mode, at: event.observedAt))
        }

        switch event.kind {
        case .sessionStarted:
            snapshot = SessionReducer.reduce(
                snapshot,
                event: .sessionStarted(mode: event.mode, at: event.observedAt)
            )
        case .sessionEnded:
            snapshot = SessionReducer.reduce(snapshot, event: .sessionClosed(at: event.observedAt))
        case .turnStarted:
            // An event that does not state a mode keeps the one the session already knows.
            // `docs/implementation-plan.md` says a missing `permission_mode` means the mode
            // is unknown and is never guessed — and guessing `standard` here turned a
            // session that had started in plan mode into a working one on its next prompt.
            snapshot = SessionReducer.reduce(
                snapshot,
                event: .turnStarted(mode: event.mode ?? snapshot.mode, at: event.observedAt)
            )
        case .activityStarted:
            let activity = SessionActivity(
                id: event.activityID ?? "unknown-activity",
                kind: event.activityKind ?? .tool,
                startedAt: event.observedAt,
                outlivesTurn: event.activityOutlivesTurn,
                outlivesItsCall: event.activityOutlivesItsCall
            )
            snapshot = SessionReducer.reduce(snapshot, event: .activityStarted(activity, at: event.observedAt))
        case .activityCompleted:
            snapshot = SessionReducer.reduce(
                snapshot,
                event: .activityCompleted(id: event.activityID ?? "unknown-activity", at: event.observedAt)
            )
        case .activityFailed:
            snapshot = SessionReducer.reduce(
                snapshot,
                event: .activityFailed(id: event.activityID ?? "unknown-activity", at: event.observedAt)
            )
        case .userInputRequired:
            snapshot = SessionReducer.reduce(
                snapshot,
                event: .userInputRequired(
                    reason: event.userInputRequestKind ?? .approval,
                    activityID: event.activityID,
                    at: event.observedAt
                )
            )
        case .turnCompleted:
            snapshot = SessionReducer.reduce(snapshot, event: .turnCompleted(at: event.observedAt))
        case .turnFailed:
            snapshot = SessionReducer.reduce(snapshot, event: .failed(at: event.observedAt))
        case .turnInterrupted:
            snapshot = SessionReducer.reduce(snapshot, event: .turnInterrupted(at: event.observedAt))
        case .statusUpdated:
            if let contextTelemetry = event.contextTelemetry {
                snapshot.contextTelemetry = contextTelemetry
            }
        }

        // Never backwards. A late event is still evidence of activity, but the age this
        // drives — the row's timer and the retention clock — is the age of the newest thing
        // heard, not of the last packet to arrive.
        snapshot.lastObservedAt = max(previouslyObservedAt, snapshot.lastObservedAt)

        snapshots[snapshotID] = snapshot
        return snapshot
    }

    /// Applies one fact read out of a session's own transcript, and answers whether it
    /// changed anything.
    ///
    /// Deliberately not a direct call into `SessionReducer`. A transcript read is
    /// structurally a source of late facts — the poll is seconds behind by design, and a
    /// re-sync arrives as a burst — so it passes through the same two rules `ingest`
    /// enforces: a closed session is terminal, and the age that drives the row's timer and
    /// the retention clock never moves backwards.
    ///
    /// `nil` for a session that is unknown, closed, or left as it was in every respect but
    /// its age. Most facts are that last case: the transcript records the end of every call,
    /// including the ones a hook already reported, so a non-`nil` result is the interesting
    /// one — something the hooks did not deliver.
    ///
    /// The age is excluded from that comparison on purpose. It moves for every fact, so
    /// including it would make every fact look like a disagreement and bury the real ones.
    @discardableResult
    public mutating func apply(_ fact: TranscriptFact, toSessionWithID id: String) -> SessionSnapshot? {
        guard let previous = snapshots[id], previous.phase != .sessionClosed else {
            return nil
        }

        var next: SessionSnapshot
        switch fact {
        case let .callReturned(activityID, at):
            next = SessionReducer.reduce(previous, event: .activityCompleted(id: activityID, at: at))
        case let .callFailed(activityID, at):
            next = SessionReducer.reduce(previous, event: .activityFailed(id: activityID, at: at))
        case let .workEnded(activityID, at):
            next = SessionReducer.reduce(previous, event: .workEnded(id: activityID, at: at))
        case let .callStarted(activityID, kind, at):
            // Through `activityObserved`, not `activityStarted`: a call read out of the
            // transcript is a late witness and must not move the phase. See `SessionReducer`.
            next = SessionReducer.reduce(
                previous,
                event: .activityObserved(
                    SessionActivity(id: activityID, kind: kind, startedAt: at),
                    at: at
                )
            )
        case let .turnInterrupted(at):
            // The one fact here that retracts state wholesale rather than closing one named
            // call, so it is the one that has to be in order. A person who stops a turn and
            // immediately types the next one is ahead of this reader: the marker is still
            // unread when the new turn's hook lands, and applying it a poll later would empty
            // a turn that had just begun. Anything heard after the interruption was written
            // means the interruption is already answered.
            //
            // The comparison only works because both sides come from the same clock — the
            // record's own timestamp, and an age moved only by observations that carry one.
            // `callReturned` and `workEnded` need no such guard: they name a call, and closing
            // one that is already closed changes nothing whatever the order.
            guard at >= previous.lastObservedAt else {
                return nil
            }
            next = SessionReducer.reduce(previous, event: .turnInterrupted(at: at))
        }
        next.lastObservedAt = max(previous.lastObservedAt, next.lastObservedAt)

        // Reading the file is itself evidence the session is alive, so a fact that changed
        // nothing else still moves the age forward. A session whose hooks have died but
        // whose transcript is being read is being watched, and must not be reported as
        // silent for a reason that is not true.
        snapshots[id] = next

        var withoutAge = next
        withoutAge.lastObservedAt = previous.lastObservedAt
        return withoutAge == previous ? nil : next
    }

    /// Applies what a session said about itself in its own transcript.
    ///
    /// Never a lifecycle fact: not one field here can move a phase, which is why it is a
    /// separate entry point rather than another case of `apply`. A field the reading is silent
    /// about keeps what the snapshot had — one increment carries a turn's model and no counts,
    /// the next the other way round, and neither should blank the other's finding.
    ///
    /// The context percentage is computed here and only here, out of two numbers the agent
    /// wrote in one record. That is what makes it honest: the rule kept for Claude — a count
    /// read from a transcript never wears a percentage measured elsewhere — is about two
    /// measurements passing for one, which two halves of a single record are not.
    @discardableResult
    public mutating func applySignals(
        _ signals: TranscriptSignals,
        toSessionWithID id: String
    ) -> SessionSnapshot? {
        guard let previous = snapshots[id], previous.phase != .sessionClosed, !signals.isEmpty else {
            return nil
        }

        var next = previous
        next.modelName = signals.modelName ?? next.modelName
        next.reasoningEffort = signals.reasoningEffort ?? next.reasoningEffort
        next.gitBranch = signals.gitBranch ?? next.gitBranch
        next.threadKind = signals.threadKind ?? next.threadKind
        next.threadNickname = signals.threadNickname ?? next.threadNickname
        if let tokens = signals.contextInputTokens {
            next.contextTelemetry = SessionContextTelemetry(
                totalInputTokens: tokens,
                // Held at a full context rather than dropped beyond it. The count and the
                // window are written at different moments of the same turn, so a little over
                // is a rounding of the truth — and going quiet exactly as the context fills
                // would lose the number at the moment it matters most.
                usedPercentage: signals.contextWindowTokens.map {
                    min(100, 100 * Double(tokens) / Double($0))
                }
            )
        }

        guard next != previous else {
            return nil
        }
        snapshots[id] = next
        return next
    }

    /// Takes what a session says about itself from somewhere other than an event.
    ///
    /// Separate from `ingest` for the reason `applySignals` is: nothing here is a lifecycle
    /// fact, so none of it may move a phase. The caller is the transcript reader, which is
    /// the only source of these values while no hook is arriving — after a restart, most of
    /// all, when the remembered copy is as old as the app's last run.
    @discardableResult
    public mutating func applyDescription(
        _ description: SessionDescription,
        toSessionWithID id: String
    ) -> SessionSnapshot? {
        guard let previous = snapshots[id], previous.phase != .sessionClosed, !description.isEmpty else {
            return nil
        }

        let next = Self.merged(previous, with: description)
        guard next != previous else {
            return nil
        }
        snapshots[id] = next
        return next
    }

    /// Each field is merged on its own: a reading that resolved a branch but not a title must
    /// not blank the title the session already had.
    private static func merged(
        _ snapshot: SessionSnapshot,
        with description: SessionDescription
    ) -> SessionSnapshot {
        var merged = snapshot
        merged.title = description.title ?? merged.title
        merged.projectName = description.projectName ?? merged.projectName
        merged.gitBranch = description.gitBranch ?? merged.gitBranch
        if let tokens = description.contextInputTokens {
            // The percentage is dropped, not carried over. It only ever arrives from a
            // provider that measured it together with its own token count, and printing it
            // beside a count read later from a transcript would show two different
            // measurements as though they were one.
            merged.contextTelemetry = SessionContextTelemetry(totalInputTokens: tokens)
        }
        return merged
    }

    /// Records that a session was heard from, without saying anything about what it said.
    ///
    /// A transcript that grew is evidence its session is alive even when not one line in it
    /// was a fact this app takes: a turn spent thinking, or writing a long answer, calls
    /// nothing and delivers no hook, and its file grows the whole time. Without this the
    /// silence rule would call that session silent while the reader was busy reading it.
    ///
    /// Takes the time the record was written rather than the time it was read, so the age
    /// stays comparable with every other observation — including the one `apply` checks an
    /// interruption against.
    @discardableResult
    public mutating func markObserved(at: Date, forSessionWithID id: String) -> SessionSnapshot? {
        guard
            var snapshot = snapshots[id],
            snapshot.phase != .sessionClosed,
            at > snapshot.lastObservedAt
        else {
            return nil
        }
        snapshot.lastObservedAt = at
        snapshots[id] = snapshot
        return snapshot
    }

    /// Records how much of a session is still known rather than remembered.
    ///
    /// Separate from `ingest` because a fault is not a lifecycle fact: it must never move a
    /// phase. `nil` when nothing changed, so a caller that recomputes this on every tick
    /// does not report a change on every tick.
    ///
    /// A fault is refused outright once the session's quiet explains itself. The reader works
    /// a poll behind, so a complaint computed while a turn was running can arrive after it
    /// ended — and nothing would clear it, because a session at rest is not watched any more.
    /// This is the mirror of the rule in `SessionReducer` that drops a fault when the phase
    /// leaves work: that one is about a fault already recorded, this one about a fault still
    /// on its way.
    @discardableResult
    public mutating func setMonitoringFault(
        _ fault: MonitoringFault?,
        forSessionWithID id: String
    ) -> SessionSnapshot? {
        guard var snapshot = snapshots[id], snapshot.monitoringFault != fault else {
            return nil
        }
        if fault != nil, SessionSilence.isExpected(snapshot) {
            return nil
        }
        snapshot.monitoringFault = fault
        snapshots[id] = snapshot
        return snapshot
    }

    @discardableResult
    public mutating func markSessionClosed(id: String, at: Date) -> SessionSnapshot? {
        // Already closed is left exactly as it was, so a second signal about the same death
        // does not restart the retention clock that is about to retire it.
        guard let snapshot = snapshots[id], snapshot.phase != .sessionClosed else {
            return nil
        }

        let closed = SessionReducer.reduce(snapshot, event: .sessionClosed(at: at))
        snapshots[id] = closed
        return closed
    }

    /// Puts back sessions a previous launch knew about, and answers with what came back.
    ///
    /// Every one of them passes through `SessionHistory.remembered`, so no caller can restore
    /// a phase however carefully it built the snapshot: what may come back is decided here,
    /// next to the rules that would otherwise have to trust it.
    ///
    /// A session already known is left exactly as it is. Restoring happens once at launch,
    /// before the socket is listening, but an event that did arrive first is the live truth
    /// and a memory must never overwrite it.
    @discardableResult
    public mutating func restore(_ remembered: [SessionSnapshot]) -> [SessionSnapshot] {
        remembered
            .sorted { $0.arrivalIndex < $1.arrivalIndex }
            .compactMap { candidate in
                guard snapshots[candidate.id] == nil else {
                    return nil
                }
                var restored = SessionHistory.remembered(candidate)
                // What the file keeps and what a row may claim are two different rules, and
                // this is where they part. A wait comes back through the file — nothing else
                // could bring it back, since no hook announces a wait a second time — but a
                // row saying "waiting for you" is a claim about a person, and this app has
                // heard nothing at all. So the wait is set aside until the session's own
                // transcript answers for it, and until then the row says only `no signal`.
                if restored.phase == .waitingForUser {
                    rememberedWaits[restored.id] = SessionHistory.RememberedWait(
                        awaitedActivityID: restored.awaitedActivityID,
                        kind: restored.userInputRequestKind,
                        observedAt: restored.lastObservedAt
                    )
                    restored.phase = .disconnected
                    restored.awaitedActivityID = nil
                    restored.userInputRequestKind = nil
                }
                // Its own place, unless the engine has already handed that index out. The list
                // is sorted by this, so two rows sharing an index would leave their order to a
                // dictionary rehash — the shuffling the index exists to stop.
                restored.arrivalIndex = max(restored.arrivalIndex, nextArrivalIndex)
                snapshots[restored.id] = restored
                // Past the highest index restored, so the next new session joins at the end of
                // the list rather than taking the place of a row that is already there.
                nextArrivalIndex = restored.arrivalIndex + 1
                return restored
            }
    }

    @discardableResult
    public mutating func removeSession(id: String) -> SessionSnapshot? {
        rememberedWaits.removeValue(forKey: id)
        return snapshots.removeValue(forKey: id)
    }

    /// The sessions whose remembered wait is still unanswered, and what each was waiting on.
    ///
    /// Read by the caller that owns the transcripts: it is the one that can ask a file
    /// whether the wait holds, and it needs the awaited call's identifier to ask.
    public var rememberedWaitsAwaitingEvidence: [String: SessionHistory.RememberedWait] {
        rememberedWaits
    }

    /// Puts back a wait the file remembered, once the session's own transcript has answered
    /// for it — or drops it when nothing can.
    ///
    /// Answering is compulsory, whatever the answer: a wait nobody resolves would sit in this
    /// engine for the life of the process, and the row it belongs to would stay `no signal`
    /// with no way to find out otherwise. `nil` evidence is a complete answer meaning the file
    /// could not be asked.
    ///
    /// Refused for a session that is no longer `disconnected`: an event that arrived while
    /// the file was being read is the live truth, and it is younger than anything here.
    @discardableResult
    public mutating func confirmRememberedWait(
        forSessionWithID id: String,
        evidence: SessionHistory.RememberedWaitEvidence?
    ) -> SessionSnapshot? {
        guard let wait = rememberedWaits.removeValue(forKey: id) else {
            return nil
        }
        guard
            var snapshot = snapshots[id],
            snapshot.phase == .disconnected,
            SessionHistory.waitStillHolds(wait, evidence: evidence)
        else {
            return nil
        }
        snapshot.phase = .waitingForUser
        snapshot.awaitedActivityID = wait.awaitedActivityID
        snapshot.userInputRequestKind = wait.kind
        snapshots[id] = snapshot
        return snapshot
    }

    /// Brings the rows built from live agent processes in step with what is running now.
    ///
    /// A process no session accounts for becomes a row; a row whose process is gone leaves.
    /// Nothing here touches a session the app has actually heard from — those rows are the
    /// agent's own account of itself, and a process scan is a much poorer one.
    ///
    /// A process a session already claims gets no row of its own. That is what keeps the
    /// widget from showing the same agent twice: the session knows its own process number,
    /// and the row built from that number would be the same session seen from outside.
    ///
    /// - Parameter processes: every live agent process, as the application found them. The
    ///   caller supplies the list rather than the engine looking for it, so every rule here
    ///   can be exercised without a machine that happens to be running an agent.
    @discardableResult
    public mutating func reconcileDiscoveredProcesses(
        _ processes: [DiscoveredAgentProcess]
    ) -> DiscoveredProcessChange {
        // A closed session is excluded from the claim, and that is not tidiness. Under
        // "remove closed sessions by hand" a tombstone never retires, so it would hold its
        // process number for good — and macOS hands those out again. The next agent to land
        // on the number of a session closed earlier that day would get no row at all, with
        // nothing left to clear it.
        let claimedProcessIDs = Set(
            snapshots.values
                .filter { $0.discoveredProcess == nil && $0.phase != .sessionClosed }
                .compactMap(\.agentProcessID)
        )
        let wanted = Dictionary(
            processes
                .filter { !claimedProcessIDs.contains($0.processID) }
                .map { ($0.snapshotID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let removedIDs = snapshots.values
            .filter { $0.discoveredProcess != nil && wanted[$0.id] == nil }
            .map(\.id)
            .sorted()
        for id in removedIDs {
            snapshots.removeValue(forKey: id)
        }

        // Sorted by process number so the rows of one scan always join in the same order.
        // Dictionary order changes on rehash, and the arrival index handed out here is what
        // fixes a row's place for the rest of its life.
        let added = wanted.values
            .filter { snapshots[$0.snapshotID] == nil }
            .sorted { $0.processID < $1.processID }
            .map { process -> SessionSnapshot in
                let row = process.row(arrivalIndex: nextArrivalIndex)
                nextArrivalIndex += 1
                snapshots[row.id] = row
                return row
            }

        return DiscoveredProcessChange(added: added, removedIDs: removedIDs)
    }

    /// Hands the row built from a process over to the session that has just proved it owns
    /// it, and answers with the row that stepped aside.
    ///
    /// Called with the event that is about to be ingested: the session is about to appear
    /// under its own identifier, and the row built from its process is the same session
    /// described worse. The row's place in the list is kept for it — see
    /// `arrivalIndexLeftByProcess`.
    ///
    /// The caller gets the row back because it holds what the engine does not: the watcher
    /// that was reporting on that process, which now belongs to the session instead.
    ///
    /// A row that already carries this session's identifier is not claimed, because there is
    /// nothing to hand over: it *is* the session, recognised from a pairing a hook made
    /// earlier (`RememberedAgentProcess`). Taking it away and building it again would throw
    /// away what its own transcript had already told the row — starting with its name.
    @discardableResult
    public mutating func claimDiscoveredRow(for event: EventEnvelope) -> SessionSnapshot? {
        let arrivingID = SessionSnapshot.id(source: event.source, sessionLabel: event.sessionID)
        guard
            let processID = event.agentProcessID,
            let row = snapshots.values.first(where: { $0.discoveredProcess?.processID == processID }),
            row.id != arrivingID
        else {
            return nil
        }
        snapshots.removeValue(forKey: row.id)
        arrivalIndexLeftByProcess[processID] = row.arrivalIndex
        return row
    }

    /// Drops a closed session whose process has moved on to another one.
    ///
    /// `/resume` is the case this exists for, and it was measured: starting `claude` and
    /// resuming an earlier conversation is two sessions in one process. The first lives for
    /// about two seconds — long enough to send a start and an end — and then the resumed
    /// session starts under its own identifier on the same process. The row left behind has
    /// no name, no turn and nothing to say, and it sat on the widget for the whole retention
    /// period, or for good where a person has chosen to retire closed rows by hand.
    ///
    /// Only a closed row is dropped, and only one closed moments ago. The first makes the
    /// rule safe against events arriving out of order: a late start from an old session
    /// cannot take away the row of a live one that now holds its process number. The second
    /// keeps it from reaching rows it was never about: macOS hands process numbers out again,
    /// and under "remove closed sessions by hand" a row closed this morning still holds the
    /// number it had — a session starting on that number tonight is a stranger, not a resume.
    ///
    /// The caller gets the rows rather than their identifiers because it holds what the
    /// engine does not — the watcher on each row's process.
    @discardableResult
    public mutating func retireSessionsSuperseded(by event: EventEnvelope) -> [SessionSnapshot] {
        guard let processID = event.agentProcessID else {
            return []
        }
        let arrivingID = SessionSnapshot.id(source: event.source, sessionLabel: event.sessionID)
        let superseded = snapshots.values
            .filter { snapshot in
                snapshot.id != arrivingID
                    && snapshot.source == event.source
                    && snapshot.phase == .sessionClosed
                    && snapshot.agentProcessID == processID
                    && event.observedAt.timeIntervalSince(snapshot.lastObservedAt) <= Self.resumeHandoverWindow
            }
            .sorted { $0.id < $1.id }
        for snapshot in superseded {
            removeSession(id: snapshot.id)
        }
        return superseded
    }

    /// How long after a closed row's last word a session starting on its process number is
    /// still that row's resume. Measured at a second or two; a minute leaves room for a slow
    /// machine without reaching a row that was closed on purpose earlier in the day.
    public static let resumeHandoverWindow: TimeInterval = 60

    /// Closes every Codex session running in the desktop app. Quitting the app is an
    /// observed fact, unlike a PID check: helper processes outlive the app itself.
    @discardableResult
    public mutating func markDesktopSessionsClosed(
        source: AgentSource,
        at closedAt: Date
    ) -> [SessionSnapshot] {
        // Sorted because `snapshots` is a dictionary: an unordered public result is a trap
        // in a module whose stated invariant is that lifecycle facts are deterministic.
        let candidates = snapshots.values
            .filter { $0.source == source && $0.clientKind == .desktop && $0.phase != .sessionClosed }
            .sorted { $0.id < $1.id }
        return candidates.compactMap { markSessionClosed(id: $0.id, at: closedAt) }
    }

    /// Demotes sessions nobody can vouch for to `disconnected` — a reversible
    /// "no signal", not a claim that the session ended. The disconnect is dated at
    /// the last thing actually observed, because a timeout observes nothing.
    ///
    /// - Parameter watchedSessionIDs: sessions whose death some watcher will report on its
    ///   own. The caller supplies this rather than the engine inferring it: which watchers
    ///   exist is an application fact, and a guess here would silently stop demoting
    ///   sessions the moment the app's watching rules changed.
    @discardableResult
    public mutating func markUnwatchedSessionsDisconnected(
        now: Date,
        after threshold: TimeInterval,
        watchedSessionIDs: Set<String>
    ) -> [SessionSnapshot] {
        guard threshold > 0 else {
            return []
        }
        let candidates = snapshots.values
            .filter { snapshot in
                !watchedSessionIDs.contains(snapshot.id)
                    && SessionFreshnessEvaluator.tracksFreshness(for: snapshot.phase)
                    && now.timeIntervalSince(snapshot.lastObservedAt) >= threshold
            }
            .sorted { $0.id < $1.id }
        return candidates.map { snapshot in
            let disconnected = SessionReducer.reduce(
                snapshot,
                event: .disconnected(at: snapshot.lastObservedAt)
            )
            snapshots[snapshot.id] = disconnected
            return disconnected
        }
    }

    /// Drops closed sessions once they have been visible long enough to notice.
    @discardableResult
    public mutating func removeExpiredClosedSessions(
        now: Date,
        retention: TimeInterval
    ) -> [String] {
        guard retention >= 0 else {
            return []
        }
        let expired = snapshots.values
            .filter { $0.phase == .sessionClosed && now.timeIntervalSince($0.lastObservedAt) >= retention }
            .map(\.id)
            .sorted()
        for id in expired {
            snapshots.removeValue(forKey: id)
        }
        return expired
    }
}
