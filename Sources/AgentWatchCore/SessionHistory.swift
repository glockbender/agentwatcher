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
        remembered.monitoringFault = nil

        if let awaiting {
            remembered.discoveredProcess = nil
            remembered.phase = .waitingForUser
            remembered.awaitedActivityID = awaiting.awaitedActivityID
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
            remembered.userInputRequestKind = nil
            return remembered
        }
        return remembered
    }

    /// A wait a session was remembered in, held back until the session's own file can say
    /// whether it still holds.
    public struct RememberedWait: Equatable, Sendable {
        public let awaitedActivityID: String?
        public let kind: UserInputRequestKind?
        /// When the session was last heard from. Anything its transcript did after this is
        /// the session moving on without the app.
        public let observedAt: Date

        public init(awaitedActivityID: String?, kind: UserInputRequestKind?, observedAt: Date) {
            self.awaitedActivityID = awaitedActivityID
            self.kind = kind
            self.observedAt = observedAt
        }
    }

    /// What a session's own transcript says about the wait it was remembered in.
    ///
    /// Two questions, because neither answers alone. The awaited call having reported back
    /// says the wait is over outright — but the tail is a window, and a session that ran on
    /// for a week leaves that answer far behind it. The newest fact is what covers that: a
    /// session that did anything at all after the wait began was not waiting.
    public struct RememberedWaitEvidence: Equatable, Sendable {
        /// The awaited call reported back somewhere in the tail.
        public let awaitedCallEnded: Bool
        /// When the newest fact in the tail happened, or `nil` when the tail holds none.
        ///
        /// Facts rather than records, and the difference is measured: an `attachment` record
        /// was written while a call was still open, so "the file grew" does not mean "the
        /// session moved on". A call starting or ending does.
        public let newestFactAt: Date?

        public init(awaitedCallEnded: Bool, newestFactAt: Date?) {
            self.awaitedCallEnded = awaitedCallEnded
            self.newestFactAt = newestFactAt
        }

        /// Reads one tail's worth of facts as evidence about one wait.
        ///
        /// Here rather than in the reader that produced the bytes: this is the whole
        /// interpretation step, and it is worth being able to exercise it without a file.
        public init(facts: [TranscriptFact], awaitedActivityID: String?) {
            awaitedCallEnded = facts.contains { $0.ends(activityID: awaitedActivityID) }
            newestFactAt = facts.map(\.at).max()
        }
    }

    /// Whether a remembered wait may be put back on the row.
    ///
    /// No evidence is not weak evidence: a transcript that could not be found or read says
    /// nothing, and a row must not claim a person is being waited for on the strength of a
    /// memory alone. `false` is the answer that costs nothing — the row stays `no signal`,
    /// and the session's next hook says what it is really doing.
    public static func waitStillHolds(_ wait: RememberedWait, evidence: RememberedWaitEvidence?) -> Bool {
        guard let evidence, !evidence.awaitedCallEnded else {
            return false
        }
        guard let newestFactAt = evidence.newestFactAt else {
            return true
        }
        return newestFactAt <= wait.observedAt
    }
}
