import Foundation

/// Whether a session's quiet is accounted for.
///
/// A monitor that goes quiet is telling you one of two very different things: the work ended,
/// or it has lost track. Until the transcript could be read there was no way to tell them
/// apart, so both looked the same — a row that simply stopped moving.
///
/// This is the rule that separates them, and it is also what decides when there is any point
/// reading a transcript: a session whose quiet is already explained has nothing left to find.
public enum SessionSilence {
    /// True when the phase itself says why nothing is happening.
    ///
    /// The turn ended, a person is being waited for, the session is closed or lost, or it is
    /// at rest between turns. Nothing more will arrive until that changes, so a reader has
    /// nothing to look for and a timer has nothing to wake for.
    ///
    /// The unexplained cases are the ones where the session claims to be busy — planning,
    /// executing, waiting on subtasks. Quiet there is normal for minutes at a time and is not
    /// a fault by itself, but it is the only quiet whose ending might never be reported, which
    /// is precisely what the transcript is read to find.
    public static func isExpected(_ snapshot: SessionSnapshot) -> Bool {
        !snapshot.phase.claimsWork
    }

    /// Two minutes. A turn spent thinking rather than calling anything is real and can run
    /// long, so the threshold is set well past what that takes; two minutes of a session that
    /// claims to be working with nothing running under it is not a pause anyone recognises.
    public static let defaultUnexplainedAfter: TimeInterval = 120

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
