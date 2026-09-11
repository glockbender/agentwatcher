import Foundation

/// Why the app is not sure it still knows what a session is doing.
///
/// Monitoring degrades in ways nothing else reports. The file a session writes may not be
/// where it is looked for; it may be unreadable; a session may claim to be working while
/// neither source says anything at all. Every one of those used to look identical to a
/// healthy quiet session — a row that simply stopped moving — which is the one failure mode
/// a monitor must not have, because the reader cannot tell it from good news.
///
/// A fault never moves a phase. The phase says what the session is doing; the fault says how
/// much of that is still known rather than remembered.
public enum MonitoringFault: String, Codable, Equatable, Sendable, CaseIterable {
    /// Nothing under the agent's transcript root is named after this session.
    ///
    /// Normal for the first seconds of a session — the file appears when the agent writes its
    /// first record — so a caller reports this only after a grace period. Past that it means
    /// the naming convention `TranscriptLocator` relies on no longer holds, or the root moved.
    case transcriptNotFound
    /// The file was found and could not be read: permissions, a file deleted underneath, a
    /// volume that went away.
    case transcriptUnreadable
    /// More had been appended than a live session can produce between two reads, so the
    /// reader skipped to the end instead of parsing it.
    ///
    /// Whatever was in between is gone. That is precisely why it is reported: a re-sync is
    /// the one recovery that quietly loses facts, and absorbing it would leave the widget
    /// confidently wrong.
    ///
    /// Unlike the others this is an event, not a state: the next successful read clears it,
    /// so the marker shows for about one poll. The durable record is the line it writes to
    /// the debug log. Deliberate — a fault that latched would need a way to be dismissed,
    /// and there is nothing for a person to do about a re-sync except know it happened.
    case transcriptResynchronized
    /// The session claims to be working, nothing is running under it, and neither source has
    /// said anything for a long time. See `SessionSilence.isUnexplained`.
    case unexplainedSilence
}
