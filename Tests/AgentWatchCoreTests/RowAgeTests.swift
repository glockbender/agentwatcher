import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// A row's age never moves backwards, whichever way the news arrives.
///
/// It drives the row's timer and the retention clock, and both answer "how long since the
/// newest thing anybody heard" — not "how long since the last packet to arrive". Events do
/// arrive late and out of order, the protocol is asked to survive that, and a transcript read
/// is structurally late by design.
///
/// The rule used to be written three times in three spellings, once per method that could
/// break it, with nothing checking that a fourth method had it at all. This is that check.
final class RowAgeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 4_000)

    func testNoWayIntoTheEngineMovesARowsAgeBackwards() throws {
        let newest = start + 600
        let stale = start + 60

        for (name, write) in writes {
            var engine = SessionStateEngine()
            try engine.ingest(testEvent(sessionLabel: "abc", observedAt: start, agentProcessID: 501))
            try engine.ingest(
                testEvent(sessionLabel: "abc", kind: .turnStarted, observedAt: newest, agentProcessID: 501))
            XCTAssertEqual(engine.snapshots["claude:abc"]?.lastObservedAt, newest, name)

            try write(&engine, stale)

            XCTAssertEqual(
                engine.snapshots["claude:abc"]?.lastObservedAt,
                newest,
                "\(name) took the row's age back to the late news it carried"
            )
        }
    }

    /// Every way a dated fact reaches a row. Named so a failure says which one.
    private var writes: [(String, (inout SessionStateEngine, Date) throws -> Void)] {
        [
            (
                "receive",
                { engine, at in
                    try engine.ingest(
                        testEvent(sessionLabel: "abc", kind: .turnCompleted, observedAt: at, agentProcessID: 501))
                }
            ),
            (
                "apply(fact:)",
                { engine, at in
                    engine.apply(.callStarted(activityID: "late", kind: .tool, at: at), toSessionWithID: "claude:abc")
                }
            ),
            (
                "markObserved",
                { engine, at in
                    engine.markObserved(at: at, forSessionWithID: "claude:abc")
                }
            ),
            (
                "markSessionClosed",
                { engine, at in
                    engine.markSessionClosed(id: "claude:abc", at: at)
                }
            ),
        ]
    }
}
