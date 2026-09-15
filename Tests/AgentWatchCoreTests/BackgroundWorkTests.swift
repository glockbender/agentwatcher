import Foundation
import XCTest

@testable import AgentWatchCore

/// Work a session leaves running when its turn ends.
///
/// The turn really is over — `completed` is the honest phase for it — but the session is not
/// free: a command it started is still running, and its ending is what will wake the session
/// for the next turn. Without this the row said `completed` and nothing else, and the one
/// case that matters most was invisible: a foreground command Claude Code moved into the
/// background itself after its timeout, which no `run_in_background` flag ever announced.
///
/// Measured on Claude Code 2.1.272 — see `docs/measurements.md`.
final class BackgroundWorkTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000)

    func testStopCarriesTheWorkTheTurnLeftRunning() throws {
        let event = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "Stop",
            payload: .object(["session_id": .string("id_session")]),
            observedAt: start,
            backgroundWork: [.shell]
        )

        XCTAssertEqual(event.kind, .turnCompleted)
        XCTAssertEqual(event.backgroundWork, [.shell])
    }

    /// The array is a fact about the session, not about the call that happens to carry it, so
    /// it reaches the snapshot whole and the row decides what to say about it.
    func testACompletedSessionRemembersWhatIsStillRunning() throws {
        var engine = SessionStateEngine()

        let completed = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "Stop",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start,
                backgroundWork: [.shell, .monitor]
            )
        )

        XCTAssertEqual(completed.phase, .completed, "the turn did end")
        XCTAssertEqual(completed.backgroundWork, [.shell, .monitor])
    }

    /// `Stop` is the only hook that carries the array, so silence must not be read as an
    /// answer. Were it, the session's next event would quietly clear work that is still
    /// running.
    func testAnEventThatSaysNothingLeavesTheKnownWorkAlone() throws {
        var engine = SessionStateEngine()
        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "Stop",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start,
                backgroundWork: [.shell]
            )
        )

        let afterSilentEvent = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "StatusLine",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(afterSilentEvent.backgroundWork, [.shell])
    }

    /// The end of the background work is what wakes the session, so the next turn starting is
    /// the moment the list stops being true. The same bound the reducer already uses to sweep
    /// a background shell — measured on this project's own event log, a session begins a turn
    /// within a second of its background task reporting in.
    ///
    /// Back to nothing reported, and not to an empty list: only a `Stop` ever states what is
    /// running, and an empty list is a statement. Emptied here, the row read it as the session
    /// saying nothing was running and stopped counting a shell started in that very turn.
    func testTheNextTurnClearsTheWorkTheLastOneLeft() throws {
        var engine = SessionStateEngine()
        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "Stop",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start,
                backgroundWork: [.shell]
            )
        )

        let working = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "UserPromptSubmit",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start.addingTimeInterval(30)
            )
        )

        XCTAssertNil(working.backgroundWork)
    }

    /// Anything running as this user can write to the socket, so a list arriving over it is
    /// trusted no further than the text beside it. A session runs a handful of background
    /// tasks; a thousand is not a session, it is a payload.
    func testAnAbsurdlyLongListIsCappedRatherThanBelieved() throws {
        let event = try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: "Stop",
            payload: .object(["session_id": .string("id_session")]),
            observedAt: start,
            backgroundWork: Array(repeating: .shell, count: 500)
        )

        XCTAssertEqual(event.backgroundWork?.count, HookIngressRequest.maximumBackgroundTaskCount)
    }

    /// A `Stop` with an empty array is an answer, and the opposite one: the work has ended
    /// and the session really has nothing left running.
    func testAStopWithNothingRunningClearsWhatTheLastOneLeft() throws {
        var engine = SessionStateEngine()
        _ = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "Stop",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start,
                backgroundWork: [.shell]
            )
        )

        let second = try engine.ingest(
            try HookEventNormalizer.normalize(
                source: .claude,
                declaredEvent: "Stop",
                payload: .object(["session_id": .string("id_session")]),
                observedAt: start.addingTimeInterval(60),
                backgroundWork: []
            )
        )

        XCTAssertEqual(second.backgroundWork, [])
    }
}
