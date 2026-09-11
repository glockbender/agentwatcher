import Foundation

/// A presentation-only measure of hook activity. Neither `quiet` nor `noRecentActivity`
/// changes a session's lifecycle phase: a quiet agent may still be doing legitimate
/// long-running work.
///
/// A much longer threshold does change the phase, but that lives in
/// `SessionStateEngine.markUnwatchedSessionsDisconnected` and applies only to sessions
/// no watcher can vouch for. See `defaultDisconnectAfter`.
public enum SessionFreshness: Equatable, Sendable {
    case current
    case quiet
    case noRecentActivity
}

public enum SessionFreshnessEvaluator {
    public static let defaultQuietAfter: TimeInterval = 15
    public static let defaultStaleAfter: TimeInterval = 60

    /// Deliberately far beyond the presentation thresholds above, and applied only to
    /// sessions no watcher can vouch for.
    ///
    /// It is not a claim that the session died. A single long build emits no hook events
    /// while it runs, so it will cross any threshold eventually; what the phase says is
    /// exactly what is known — nothing has been heard — and one event brings the session
    /// straight back. Half an hour is chosen so that ordinary long builds stay clear of it.
    public static let defaultDisconnectAfter: TimeInterval = 1_800

    public static func evaluate(
        _ snapshot: SessionSnapshot,
        now: Date,
        quietAfter: TimeInterval = defaultQuietAfter,
        staleAfter: TimeInterval = defaultStaleAfter
    ) -> SessionFreshness {
        guard quietAfter >= 0, staleAfter >= quietAfter, tracksFreshness(for: snapshot.phase) else {
            return .current
        }

        let elapsed = now.timeIntervalSince(snapshot.lastObservedAt)
        guard elapsed >= quietAfter else {
            return .current
        }
        return elapsed >= staleAfter ? .noRecentActivity : .quiet
    }

    /// Age is only worth showing where the session claims to be doing something: a phase
    /// that explains its own quiet has nothing for a clock to add.
    public static func tracksFreshness(for phase: SessionPhase) -> Bool {
        phase.claimsWork
    }
}
