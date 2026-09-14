import Foundation

/// Everything one event did to the widget's rows.
///
/// The answer `SessionStateEngine.receive` hands back, and the whole of it: which row the
/// event landed on, which rows left as it did, and what the engine decided along the way.
/// Read in place of asking the engine again — a second question about an event already
/// applied is answered by an engine that has moved on.
public struct RowChange: Equatable, Sendable {
    /// Why an event was given no row at all.
    public enum Withholding: Equatable, Sendable {
        /// A background session has said it exists and nothing more. Measured on Claude Code
        /// 2.1.270: the agents view refills itself from pre-warmed processes, each of which
        /// starts and ends within seconds, so a row per start was three empty rows in
        /// fifteen seconds. The row waits for the session to do something.
        case announcedItself
        /// And then it ended without ever doing it. The row it never had must not arrive as
        /// a tombstone instead.
        case endedWithoutWorking
    }

    /// A row that left the widget as this event landed, and why.
    public struct Departure: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// A row the app had built from a live process, now spoken for by the session
            /// that runs on it. Its place in the list is kept.
            case claimedByItsOwnSession
            /// A closed row whose process now runs this session — the two-second session
            /// `--resume` leaves behind.
            case itsProcessNowRunsAnother
            /// A copy's own row, folded into the row of the session it continues.
            case foldedIntoTheRowItContinues
        }

        public let row: SessionSnapshot
        public let reason: Reason

        public init(row: SessionSnapshot, reason: Reason) {
            self.row = row
            self.reason = reason
        }
    }

    /// The row the event landed on, or `nil` when it took none — see `withheld`.
    public let row: SessionSnapshot?
    /// Set when the event was given no row, and why.
    public let withheld: Withholding?
    /// Rows that left as this one landed. The caller drops whatever it holds on each — a
    /// watcher on the process, say — and says out loud only what is news.
    public let rowsThatLeft: [Departure]
    /// What the engine decided about copies of this session, when it decided anything.
    public let note: SessionStateEngine.IngestNote?

    /// The rows that left for one reason, which is how a caller names what it is looking at.
    public func rowsThatLeft(_ reason: Departure.Reason) -> [SessionSnapshot] {
        rowsThatLeft.filter { $0.reason == reason }.map(\.row)
    }

    public init(
        row: SessionSnapshot?,
        withheld: Withholding?,
        rowsThatLeft: [Departure],
        note: SessionStateEngine.IngestNote?
    ) {
        self.row = row
        self.withheld = withheld
        self.rowsThatLeft = rowsThatLeft
        self.note = note
    }
}
