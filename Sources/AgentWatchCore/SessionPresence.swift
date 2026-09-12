import Foundation

/// What a person can still do about a session, and when.
///
/// A statement about sessions rather than about views, which is why it is in this target
/// and not beside the row that draws the buttons: `AGENTS.md` wants rules like these
/// checkable without an application.
public enum SessionPresence {
    /// Whether `↗` can ever reach this session — and since `claude attach`, it always can.
    ///
    /// Asks nothing about the running system — only what kind of place the session itself
    /// said it is in. A background session used to be the one row where the answer was no:
    /// the agent runs it in a pty of its own, its process tree ends at `launchd` with no
    /// application above it, and no window will ever appear. It has a door instead of a
    /// window — `claude attach <job id>` shows it in any terminal — so `↗` opens that door in
    /// a new terminal tab (`BackgroundSessionAttach`). Every other row has a host that may be
    /// running, may have quit, or may not have been found this second, and none of that is
    /// predicted here: a button greyed on a guess about the host is wrong whenever the guess is.
    ///
    /// Kept as a rule the widget asks rather than deleted, because this is the one place that
    /// would say so if a kind of session became unreachable again.
    public static func canBeBroughtForward(_ snapshot: SessionSnapshot) -> Bool {
        true
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
