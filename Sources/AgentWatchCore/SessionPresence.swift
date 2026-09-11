import Foundation

/// What a person can still do about a session, and when.
///
/// A statement about sessions rather than about views, which is why it is in this target
/// and not beside the row that draws the buttons: `AGENTS.md` wants rules like these
/// checkable without an application.
public enum SessionPresence {
    /// Whether `↗` can ever reach this session.
    ///
    /// Asks nothing about the running system — only what kind of place the session itself
    /// said it is in. A background session is the one row where the answer is no and cannot
    /// change: the agent runs it in a pty of its own, and its process tree ends at `launchd`
    /// with no application above it. Every other row has a host that may be running, may
    /// have quit, or may not have been found this second, and none of that is predicted
    /// here: a button greyed on a guess about the host is wrong whenever the guess is.
    public static func canBeBroughtForward(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.clientKind != .background
    }

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
    public static func isDismissible(_ snapshot: SessionSnapshot, now: Date) -> Bool {
        if snapshot.phase == .sessionClosed || snapshot.phase == .disconnected {
            return true
        }
        if snapshot.monitoringFault != nil {
            return true
        }
        return now.timeIntervalSince(snapshot.lastObservedAt) >= SessionFreshnessEvaluator.defaultDisconnectAfter
    }
}
