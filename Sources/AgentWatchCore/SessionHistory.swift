import Foundation

/// What a session brings back from a previous launch of the app.
///
/// The app learns of a session only from a hook, so after a restart the widget is empty
/// until every session happens to do something. Remembering the sessions closes that gap —
/// but only for the half of a session that is still true when nobody was watching.
public enum SessionHistory {
    /// What of a session list is worth keeping until the next launch.
    ///
    /// A closed session is left out: its host is gone, so nothing could vouch for the row on
    /// the next launch, and a tombstone from the previous one is not what an empty widget is
    /// missing.
    ///
    /// A row built from a live process is left out for the opposite reason — nothing about
    /// it is worth remembering, because the next launch looks for the process itself. Kept,
    /// it could only come back as a row for an agent that has since exited.
    /// - Parameter awaiting: waits the engine has set aside, by session identifier. A wait
    ///   under check lives in memory only, so the file has to go on carrying it — see
    ///   `remembered(_:awaiting:)`.
    public static func records(
        of sessions: some Collection<SessionSnapshot>,
        awaiting: [String: RememberedWait] = [:]
    ) -> [SessionSnapshot] {
        sessions
            .filter { $0.phase != .sessionClosed && $0.discoveredProcess == nil }
            .map { remembered($0, awaiting: awaiting[$0.id]) }
    }

    /// One session reduced to what outlives a restart.
    ///
    /// Everything describing the session stays: it is a person's project, branch and model,
    /// and none of that changes because this app was not running. Everything describing what
    /// the session was *doing* goes, and the reason is sharper than the invariant it also
    /// follows from (`AGENTS.md`: lifecycle facts are deterministic). A session restored as
    /// `executing` would come back with an empty activity list and an age of however long
    /// the app was down — which is precisely the shape `SessionSilence.isUnexplained`
    /// reports as a fault. Every restart would raise a warning triangle over every session
    /// that had been working, and an alarm that is always wrong is worse than none.
    ///
    /// `disconnected` rather than `idle` for the same reason spelled the other way: `idle`
    /// claims the session is at rest between turns, which nobody observed. `disconnected`
    /// already means exactly what is known — nothing has been heard — and one event brings
    /// the session straight back to the truth.
    ///
    /// Written as a copy with fields cleared rather than a fresh `init`: a field added to
    /// `SessionSnapshot` later is then carried over by default instead of silently dropped.
    /// - Parameter awaiting: a wait `SessionStateEngine.restore` has set aside for this
    ///   session, if there is one. The engine demotes such a row to `disconnected` and holds
    ///   the wait in memory until the session's transcript answers for it — and the
    ///   application publishes inside that window, which writes the file. Taking the demoted
    ///   row at face value there would make the launch that exists to bring the wait back the
    ///   very thing that erased it, so while the question is open the file keeps saying what
    ///   it said before.
    public static func remembered(
        _ snapshot: SessionSnapshot,
        awaiting: RememberedWait? = nil
    ) -> SessionSnapshot {
        var remembered = snapshot
        remembered.activities = []
        // And what the last turn left running goes with them, for the same reason: the row
        // draws that list as something happening now, and after a restart nobody is left to
        // correct it until the session speaks again. Keeping it would also draw two sessions
        // in one real state differently — the one whose `Stop` reported a list would carry a
        // counter across the restart, the one whose background call this app merely counted
        // would not, having just had its activities cleared on the line above.
        remembered.backgroundWork = nil
        remembered.monitoringFault = nil

        if let awaiting {
            remembered.discoveredProcess = nil
            remembered.phase = .waitingForUser
            remembered.awaitedActivityID = awaiting.awaitedActivityID
            remembered.awaitedAgentID = awaiting.awaitedAgentID
            remembered.userInputRequestKind = awaiting.kind
            return remembered
        }
        // A row is only ever built from a process while that process is running, and the
        // next launch decides that for itself. Cleared here as well as filtered by
        // `records`, so a file edited by hand cannot restore a row that claims to be a
        // process nobody looked for.
        remembered.discoveredProcess = nil

        // One phase is worth keeping, and the file keeps it as a question rather than as an
        // answer. A session waiting for a person is the one state that does not decay: it
        // was true when the app stopped, and nothing but that person can end it — which is
        // also why it is the state a restart most needs back, since no hook is coming to
        // announce it again.
        //
        // `SessionStateEngine.restore` still refuses to claim it. This function says what
        // the file keeps; the engine says what a row may assert, and those stopped being the
        // same rule here.
        guard snapshot.phase == .waitingForUser else {
            remembered.phase = .disconnected
            remembered.awaitedActivityID = nil
            remembered.awaitedAgentID = nil
            remembered.userInputRequestKind = nil
            return remembered
        }
        return remembered
    }

    /// A wait a session was remembered in, held back until the session's own file can say
    /// whether it still holds.
    public struct RememberedWait: Equatable, Sendable {
        public let awaitedActivityID: String?
        /// Which agent was asked, carried across the restart with the call. Without it the
        /// wait would come back belonging to the main thread, and the next call by any other
        /// subagent would read as its answer.
        public let awaitedAgentID: String?
        public let kind: UserInputRequestKind?
        /// When the session was last heard from, used to reject older interruptions.
        public let observedAt: Date

        public init(
            awaitedActivityID: String?,
            awaitedAgentID: String? = nil,
            kind: UserInputRequestKind?,
            observedAt: Date
        ) {
            self.awaitedActivityID = awaitedActivityID
            self.awaitedAgentID = awaitedAgentID
            self.kind = kind
            self.observedAt = observedAt
        }
    }

    /// What a session's own transcript says about the wait it was remembered in.
    ///
    /// The awaited call ending or a current interruption retracts the wait. Unrelated calls
    /// can finish while a permission dialog stays open, so their dates prove nothing about it.
    public struct RememberedWaitEvidence: Equatable, Sendable {
        /// The awaited call reported back somewhere in the tail.
        public let newestAwaitedCallEndAt: Date?
        /// A whole-turn interruption, judged against the age of the remembered wait.
        /// Late observations of calls starting preserve a wait, just as they do live.
        public let newestInterruptionAt: Date?

        public init(newestAwaitedCallEndAt: Date?, newestInterruptionAt: Date?) {
            self.newestAwaitedCallEndAt = newestAwaitedCallEndAt
            self.newestInterruptionAt = newestInterruptionAt
        }

        /// Reads one tail's worth of facts as evidence about one wait.
        ///
        /// Here rather than in the reader that produced the bytes: this is the whole
        /// interpretation step, and it is worth being able to exercise it without a file.
        public init(facts: [TranscriptFact], awaitedActivityID: String?, awaitedAgentID: String? = nil) {
            newestAwaitedCallEndAt =
                facts
                .filter { $0.ends(activityID: awaitedActivityID, agentID: awaitedAgentID) }
                .map(\.at).max()
            newestInterruptionAt = facts.compactMap { fact in
                if case let .turnInterrupted(at) = fact {
                    return at
                }
                return nil
            }.max()
        }
    }

    /// Whether a remembered wait may be put back on the row.
    ///
    /// No evidence is not weak evidence: a transcript that could not be found or read says
    /// nothing, and a row must not claim a person is being waited for on the strength of a
    /// memory alone. `false` is the answer that costs nothing — the row stays `no signal`,
    /// and the session's next hook says what it is really doing.
    public static func waitStillHolds(_ wait: RememberedWait, evidence: RememberedWaitEvidence?) -> Bool {
        guard let evidence else {
            return false
        }
        if let endedAt = evidence.newestAwaitedCallEndAt, endedAt >= wait.observedAt {
            return false
        }
        guard let newestInterruptionAt = evidence.newestInterruptionAt else {
            return true
        }
        return newestInterruptionAt < wait.observedAt
    }
}
