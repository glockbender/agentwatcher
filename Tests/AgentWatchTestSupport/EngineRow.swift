import AgentWatchCore
import Foundation

/// What a test means when it says "this event, and where it landed".
///
/// `SessionStateEngine.receive` is the only way in, and it answers with everything one event
/// did — the row, the rows that left, what was decided about copies. Most tests are about the
/// row alone, and spelling `receive(…).row` with an unwrap at each of three hundred call
/// sites would say nothing those tests are checking.
///
/// It goes through `receive` rather than around it, which is the point: the application
/// applies every event that way, and a test that took a shorter path would be exercising a
/// path nothing ships.
extension SessionStateEngine {
    /// The row this event landed on.
    ///
    /// Throws rather than returning `nil` when the event took no row at all: that is a fact
    /// about background sessions with a rule of its own, and a test that means to check it
    /// asks `receive` directly.
    @discardableResult
    public mutating func ingest(_ event: EventEnvelope) throws -> SessionSnapshot {
        guard let row = try receive(event).row else {
            throw EngineRowError.theEventTookNoRow(sessionLabel: event.sessionID)
        }
        return row
    }
}

public enum EngineRowError: Error, Equatable {
    /// The engine gave this event no row — ask `receive` when that is the subject.
    case theEventTookNoRow(sessionLabel: String)
}
