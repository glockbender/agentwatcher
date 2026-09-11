import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// What a session brings back from a previous launch, and what it must leave behind.
final class SessionHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The lifecycle is the half that cannot survive, and the reason is stronger than the
    /// invariant it also follows from: a session restored as `executing` has an empty
    /// activity list and an old age, which is exactly the shape `SessionSilence` calls an
    /// unexplained silence. Every restart would raise a warning triangle on every session
    /// that had been working — an alarm that is always wrong.
    func testARestoredSessionKeepsNoLifecycleAndRaisesNoAlarm() {
        var engine = SessionStateEngine()
        let working = SessionSnapshot(
            id: "claude:abc",
            source: .claude,
            arrivalIndex: 0,
            phase: .executing,
            userInputRequestKind: .approval,
            awaitedActivityID: "call-1",
            activities: [SessionActivity(id: "call-1", kind: .shell, startedAt: now - 600)],
            lastObservedAt: now - 600,
            monitoringFault: .unexplainedSilence
        )

        let restored = engine.restore([working])

        XCTAssertEqual(restored.map(\.id), ["claude:abc"])
        let stored = engine.snapshots["claude:abc"]
        XCTAssertEqual(stored?.phase, .disconnected)
        XCTAssertEqual(stored?.activities, [])
        XCTAssertNil(stored?.awaitedActivityID)
        XCTAssertNil(stored?.userInputRequestKind)
        XCTAssertNil(stored?.monitoringFault)
        XCTAssertFalse(SessionSilence.isUnexplained(try XCTUnwrap(stored), now: now))
    }

    /// Order is the one thing a restart could quietly ruin. The index a session was given
    /// when it first appeared is kept, so the rows come back where they were — and the
    /// engine's counter has to move past them, or the next new session would be handed an
    /// index a restored row already holds and the two would trade places on every rehash.
    func testRestoredRowsKeepTheirPlaceAndANewSessionJoinsAfterThem() throws {
        var engine = SessionStateEngine()

        let restored = engine.restore([
            remembered(id: "claude:second", arrivalIndex: 7),
            remembered(id: "claude:first", arrivalIndex: 5),
        ])

        XCTAssertEqual(restored.map(\.id), ["claude:first", "claude:second"])
        XCTAssertEqual(engine.snapshots["claude:first"]?.arrivalIndex, 5)
        XCTAssertEqual(engine.snapshots["claude:second"]?.arrivalIndex, 7)

        let fresh = try engine.ingest(event(sessionLabel: "third"))
        XCTAssertEqual(fresh.arrivalIndex, 8)
    }

    /// Restoring runs at launch, before the socket is listening, so this is a guard rather
    /// than an everyday case. It is still the one that matters: an event is the live truth
    /// and a memory of the same session is by definition older than it.
    func testAMemoryNeverOverwritesASessionTheAppHasAlreadyHeardFrom() throws {
        var engine = SessionStateEngine()
        let live = try engine.ingest(event(sessionLabel: "abc"))
        XCTAssertEqual(live.phase, .idle)

        let restored = engine.restore([remembered(id: live.id, arrivalIndex: 4)])

        XCTAssertEqual(restored, [])
        XCTAssertEqual(engine.snapshots[live.id]?.arrivalIndex, 0)
        XCTAssertEqual(engine.snapshots[live.id]?.phase, .idle)
    }

    /// The index is what keeps the rows still, so two rows must never hold the same one. A
    /// memory is skipped when its session is already here, but a memory of a *different*
    /// session still carries an index the engine may have handed out in the meantime — and
    /// the list is sorted by it, so a tie leaves the order to whatever a dictionary rehash
    /// gives, which is the shuffling `arrivalIndex` exists to stop.
    func testARestoredRowNeverTakesAnIndexTheEngineHasAlreadyHandedOut() throws {
        var engine = SessionStateEngine()
        let live = try engine.ingest(event(sessionLabel: "fresh"))
        XCTAssertEqual(live.arrivalIndex, 0)

        let restored = engine.restore([remembered(id: "claude:from-before", arrivalIndex: 0)])

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(
            Set(engine.snapshots.values.map(\.arrivalIndex)).count,
            2,
            "two rows on one index leave their order to a rehash"
        )
    }

    private func remembered(id: String, arrivalIndex: Int) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            source: .claude,
            arrivalIndex: arrivalIndex,
            phase: .executing,
            lastObservedAt: now - 600
        )
    }

    private func event(sessionLabel: String) -> EventEnvelope {
        testEvent(sessionLabel: sessionLabel, observedAt: now)
    }
}
