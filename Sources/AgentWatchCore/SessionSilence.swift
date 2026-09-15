import Foundation

/// Whether a session's quiet is accounted for.
///
/// A monitor that goes quiet is telling you one of two very different things: the work ended,
/// or it has lost track. Until the transcript could be read there was no way to tell them
/// apart, so both looked the same — a row that simply stopped moving.
///
/// This is the rule that separates them. A second rule beside it, `mayEndWithoutAHook`,
/// decides when there is any point reading a transcript — and the two are not the same
/// question, which took a stuck row to learn.
public enum SessionSilence {
    /// True when the phase itself says why nothing is happening.
    ///
    /// The turn ended, a person is being waited for, the session is closed or lost, or it is
    /// at rest between turns. Quiet there is nobody's fault, and a timer has nothing to wake
    /// for on its account.
    ///
    /// The unexplained cases are the ones where the session claims to be busy — planning,
    /// executing, waiting on subtasks. Quiet there is normal for minutes at a time and is not
    /// a fault by itself, but three minutes of it with nothing running is.
    public static func isExpected(_ snapshot: SessionSnapshot) -> Bool {
        !snapshot.phase.claimsWork
    }

    /// True when the quiet might end with no hook announcing it — the reason a transcript is
    /// read at all.
    ///
    /// A session claiming work can be interrupted, and a call of its can succeed, with no
    /// registered hook saying so. A session waiting for a person can lose its dialog the same
    /// way: measured, Esc on a permission prompt writes `[Request interrupted by user for tool
    /// use]` into the transcript and fires nothing — not `Stop`, not `PermissionDenied`. The
    /// row read nothing while it waited, so it kept asking for an approval that had long been
    /// withdrawn. Its quiet is still no fault (`isExpected`), and still worth a look.
    ///
    /// Everything else — at rest, completed, failed, lost, closed — changes only by a hook, and
    /// reading its file would be polling in the resting state.
    public static func mayEndWithoutAHook(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.phase.claimsWork || snapshot.phase == .waitingForUser
    }

    /// Three minutes. A turn spent thinking rather than calling anything is real and can run
    /// long, so the threshold is set well past what that takes.
    ///
    /// Two of them were not past it. An advisor call is silent to both sources at once — no
    /// hook announces it and its transcript record lands only when it returns — and one was
    /// measured at 236 seconds, so every long consultation flagged a healthy session. Three
    /// minutes still does not cover that call: it delays the warning rather than abolishing
    /// it, because a threshold past every honest pause never reports a real loss either.
    /// `docs/measurements.md` holds the measurement.
    public static let defaultUnexplainedAfter: TimeInterval = 180

    /// True when a session's quiet is accounted for by nothing at all.
    ///
    /// The open activities are what make this usable. A long build is silent for minutes and
    /// is completely explained — the shell call it is running is right there in the session's
    /// own list — so silence only becomes a fault when the phase claims work and the list is
    /// empty. Without that condition every honest long-running command would be reported as
    /// a fault, and a warning that fires on healthy sessions teaches people to ignore it.
    ///
    /// The threshold measures from the last thing observed *from either source*, so a session
    /// whose hooks have stopped but whose transcript is still being read stays quiet here.
    /// That is the point: this is what is left after both sources have gone silent together.
    public static func isUnexplained(
        _ snapshot: SessionSnapshot,
        now: Date,
        after threshold: TimeInterval = defaultUnexplainedAfter
    ) -> Bool {
        guard threshold > 0, !isExpected(snapshot), snapshot.activities.isEmpty else {
            return false
        }
        return now.timeIntervalSince(snapshot.lastObservedAt) >= threshold
    }

    /// Whether a session's quiet should be reported as a fault this moment, and the order the
    /// four reasons not to report it are asked in.
    ///
    /// This is a rule about sessions, so it belongs here rather than inside the reader that
    /// happens to notice it — where it could only be exercised through the AppKit target, and
    /// so was not exercised at all.
    ///
    /// - Parameters:
    ///   - alreadyFaulted: the reading itself reported a problem. That wins: it says *why*
    ///     nothing is known, which is a better answer than saying nothing is known.
    ///   - sawFreshRecord: something was read for this session this moment. The snapshot is
    ///     one publish old, so a session just heard from still looks as quiet as it was a
    ///     tick ago, and anything read now settles the question before the stale age can
    ///     answer it wrongly.
    ///   - isBeingRead: a file for this session is in hand. Without one nothing is being read
    ///     at all, and the age stops moving for that reason alone — for a whole minute, once
    ///     a failed read books the back-off. Calling that silence would replace the honest
    ///     complaint already on the row, "the file cannot be read", with a wrong one.
    public static func fault(
        for snapshot: SessionSnapshot,
        alreadyFaulted: Bool,
        sawFreshRecord: Bool,
        isBeingRead: Bool,
        now: Date,
        after threshold: TimeInterval = defaultUnexplainedAfter
    ) -> MonitoringFault? {
        guard !alreadyFaulted, !sawFreshRecord, isBeingRead else {
            return nil
        }
        return isUnexplained(snapshot, now: now, after: threshold) ? .unexplainedSilence : nil
    }
}
