import Foundation

/// What a person can still do about a row, and when.
///
/// Three answers rather than two, and the third is the one a `Bool` could not give: a row
/// that is over but still held says so, with the moment its `×` starts working. Hiding the
/// button instead answered a question nobody asked — "is there a button?" — in place of the
/// one a person actually asks, which is "why can I not close this?".
public enum RowDismissal: Equatable, Sendable {
    /// By hand, now.
    case now
    /// Offered, and greyed until this moment: the session has stopped, and the row is kept
    /// in case it speaks again.
    case notYet(at: Date)
    /// Not offered at all until this moment. The session is at work or waiting for a person,
    /// and there is nothing here to dismiss — a button for it, greyed or not, would promise
    /// otherwise. Long enough silence still ends it, which is what the date says.
    case notOffered(until: Date)

    /// When this row's `×` starts working, or `nil` because it already does.
    ///
    /// Carried on the answer so that a caller who has to wake up for the moment takes it from
    /// here rather than working it out again. The same arithmetic in two places is how a
    /// threshold changed in one of them leaves a timer firing at the wrong moment, with
    /// nothing to notice.
    public var becomesDismissibleAt: Date? {
        switch self {
        case .now: nil
        case .notYet(let at), .notOffered(let at): at
        }
    }
}

/// What a person can still do about a session, and when.
///
/// A statement about sessions rather than about views, which is why it is in this target
/// and not beside the row that draws the `×`: `AGENTS.md` wants rules like these checkable
/// without an application. Whether a click can reach a session is not asked here any more:
/// every row answers a click, and what one reaches is reported afterwards by
/// `SessionHostRegistry.focus` — a refusal there is a reason a person can read, where a rule
/// here could only have been a guess about a host that changes between two clicks.
public enum SessionPresence {
    /// A session the app will never revisit on its own needs a way out by hand.
    ///
    /// `closed` is terminal. `no signal` is reversible in principle, but nothing sweeps it:
    /// freshness stops tracking that phase and retention only retires closed sessions.
    ///
    /// The third case is any phase at all once the session has been silent for longer than
    /// the disconnect threshold. Freshness deliberately does not track `waiting for user` —
    /// a person may take an hour to answer — so a session left waiting on a completion that
    /// never arrived could otherwise sit at an urgent blinking lamp with nothing able to
    /// clear it. Half an hour of total silence is enough to say nobody is coming.
    ///
    /// The fourth is a row the app has stopped being sure of. Every case above waits out a
    /// threshold because the app still believes what the row says; a fault is the app saying
    /// it does not, and a person should not have to wait half an hour to clear a row that has
    /// already announced it may be wrong.
    ///
    /// A closed terminal is the fifth, and needs no threshold: its agent is hung on the way
    /// out and cannot speak again, which the app has read off the process rather than
    /// inferred from a silence.
    ///
    /// Everything else splits by whether the session has finished. A row that has — completed
    /// or failed — is offered its button greyed, because the question "why can I not close
    /// this?" is asked exactly there. Anything still live is offered nothing, `idle`
    /// included: resting between turns is a session waiting for its person to type, and a
    /// button on a session that started a moment ago is a control nobody was looking for.
    public static func dismissal(of snapshot: SessionSnapshot, now: Date) -> RowDismissal {
        if snapshot.phase == .sessionClosed || snapshot.phase == .disconnected || snapshot.phase == .terminalClosed {
            return .now
        }
        if snapshot.monitoringFault != nil {
            return .now
        }
        let silentUntil = snapshot.lastObservedAt + SessionFreshnessEvaluator.defaultDisconnectAfter
        if now >= silentUntil {
            return .now
        }
        guard snapshot.phase == .completed || snapshot.phase == .failed else {
            return .notOffered(until: silentUntil)
        }
        return .notYet(at: silentUntil)
    }
}
