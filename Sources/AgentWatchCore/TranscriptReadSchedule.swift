import Foundation

/// When the transcript should next be read.
///
/// Reading used to run on a fixed timer, in whatever phase it happened to fall relative to
/// the events it was chasing. Here a hook pulls the next read towards itself, so the file is
/// looked at just after something happened rather than up to a whole interval later.
///
/// The three intervals answer three different questions, and all three are needed: `floor`
/// stops a burst of hooks from causing a read each, `idle` covers what no hook reports at all
/// — an interrupted turn under Claude, and the successful end of a tool call, which no
/// registered hook announces — and `coalesceWindow` gives hooks arriving together one read
/// between them.
public struct TranscriptReadSchedule: Equatable, Sendable {
    /// The shortest gap allowed between two reads.
    public let floor: TimeInterval
    /// The longest the reader may go without looking at all.
    ///
    /// Must be longer than `floor`. Equal to it, `nextRead` would always return
    /// `lastReadAt + floor` and a hook could never change anything — the schedule would be
    /// the fixed timer it replaces.
    public let idle: TimeInterval
    /// How long to wait after a hook, so hooks arriving together cause one read.
    ///
    /// Not a wait for the agent to finish writing: measured on this project's own transcript,
    /// the record is already readable before its hook fires, because the hook spends its
    /// first moments merely starting a process.
    public let coalesceWindow: TimeInterval

    public init(floor: TimeInterval, idle: TimeInterval, coalesceWindow: TimeInterval) {
        self.floor = floor
        self.idle = idle
        self.coalesceWindow = coalesceWindow
    }

    /// The moment of the next read, from the last one and the most recent hook.
    ///
    /// Deliberately takes no "now": the answer depends only on what has already happened, and
    /// whether that moment has arrived is the caller's question, not this one's.
    /// Before the first read, `lastReadAt` is the scheduling anchor, not a consumed hook boundary.
    public func nextRead(lastReadAt: Date, lastHookAt: Date?, isFirstRead: Bool = false) -> Date {
        let deadline = lastReadAt.addingTimeInterval(idle)
        guard let lastHookAt, isFirstRead || lastHookAt > lastReadAt else {
            return deadline
        }
        // Never later than the deadline: a hook is a reason to read sooner, and one arriving
        // just before a read was due must not postpone it.
        return min(
            deadline,
            max(lastHookAt.addingTimeInterval(coalesceWindow), lastReadAt.addingTimeInterval(floor))
        )
    }
}
