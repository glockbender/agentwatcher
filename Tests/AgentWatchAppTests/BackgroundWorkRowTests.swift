import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// What a finished row says about work the turn left behind.
///
/// The phase stays `completed` — the turn did end, and a background command wants nothing
/// from a person, so a lamp claiming work would interrupt for nothing. What was missing is
/// the rest of the sentence: the row said the turn was over and nothing at all about the
/// command still running, which is the whole of what a reader wanted to know.
@MainActor
final class BackgroundWorkRowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000)

    func testAFinishedRowCountsWhatItLeftRunning() {
        var completed = testSession(phase: .completed, lastObservedAt: start)
        completed.backgroundWork = [.shell, .monitor]

        let counts = activityCounts(for: completed)

        XCTAssertEqual(counts.map(\.kind), [.backgroundTask])
        XCTAssertEqual(counts.map(\.count), [2])
    }

    /// The session's own list is the better source and replaces what the app counted for
    /// itself, rather than being added to it: a command the agent asked to run in the
    /// background is one piece of work, and it is in both.
    func testTheSessionsOwnListReplacesTheCallsTheAppCounted() {
        var completed = testSession(
            phase: .waitingForChildren,
            activities: [
                SessionActivity(
                    id: "call",
                    kind: .backgroundTask,
                    startedAt: start,
                    outlivesTurn: true,
                    outlivesItsCall: true
                )
            ],
            lastObservedAt: start
        )
        completed.backgroundWork = [.shell]

        XCTAssertEqual(activityCounts(for: completed).map(\.count), [1], "one command, counted once")
    }

    /// Without a list of its own, a row still counts the background calls it saw. Sessions
    /// running against an older Claude Code, or a sender not yet reinstalled, are exactly
    /// this case, and losing the counter for them would be a regression.
    func testARowWithNoListOfItsOwnStillCountsTheCallsItSaw() {
        let waiting = testSession(
            phase: .waitingForChildren,
            activities: [
                SessionActivity(
                    id: "call",
                    kind: .backgroundTask,
                    startedAt: start,
                    outlivesTurn: true,
                    outlivesItsCall: true
                )
            ],
            lastObservedAt: start
        )

        XCTAssertEqual(activityCounts(for: waiting).map(\.count), [1])
    }

    func testTheCardNamesWhatIsStillRunning() {
        var completed = testSession(phase: .completed, lastObservedAt: start)
        completed.backgroundWork = [.shell, .shell, .monitor]

        XCTAssertTrue(
            hoverCardText(for: completed, now: start, layout: .standard)
                .contains("still running in the background: 2 shell commands · 1 monitor"),
            "the card explains the counter the row has room only to number"
        )
    }

    /// Found by drawing the card: it carried both `waiting on 1 background task` and
    /// `still running in the background: 1 shell command` — one fact twice, and the first
    /// wording states the opposite of what is true. The turn ended; it waits on nothing.
    /// `activitiesText` says as much in its own comment, and the counter it inherited from
    /// the activities contradicted it.
    func testTheCardNeverSaysTheTurnIsWaitingOnWorkItWalkedAwayFrom() {
        var completed = testSession(phase: .completed, lastObservedAt: start)
        completed.backgroundWork = [.shell]

        let card = hoverCardText(for: completed, now: start, layout: .standard)

        XCTAssertFalse(card.contains("waiting on"), "the turn ended, so it waits on nothing")
        XCTAssertTrue(card.contains("still running in the background: 1 shell command"))
    }

    /// Without a list, the background calls the app saw are still worth a line — they are the
    /// same work, and the only thing missing is the session's word for its kind.
    func testARowWithNoListStillNamesTheBackgroundCallItSaw() {
        let waiting = testSession(
            phase: .waitingForChildren,
            activities: [
                SessionActivity(
                    id: "call",
                    kind: .backgroundTask,
                    startedAt: start,
                    outlivesTurn: true,
                    outlivesItsCall: true
                )
            ],
            lastObservedAt: start
        )

        XCTAssertTrue(
            hoverCardText(for: waiting, now: start, layout: .standard).contains(
                "still running in the background: 1 task")
        )
    }

    /// A subagent is in the session's list too. Measured on Claude Code 2.1.272: a `Stop` sent
    /// while a spawned agent was still working carried
    /// `{"type": "subagent", "status": "running", "agent_type": "general-purpose"}`.
    ///
    /// It has a symbol of its own in the row and words of its own in the card, so counting it
    /// here again would draw one agent as two pieces of work.
    func testASubagentIsNotDrawnTwiceBecauseItIsInBothLists() {
        var waiting = testSession(
            phase: .waitingForChildren,
            activities: [
                SessionActivity(id: "agent", kind: .subagent, startedAt: start, outlivesTurn: true)
            ],
            lastObservedAt: start
        )
        waiting.backgroundWork = [.subagent, .shell]

        let counts = activityCounts(for: waiting)

        XCTAssertEqual(counts.map(\.kind), [.subagent, .backgroundTask])
        XCTAssertEqual(counts.map(\.count), [1, 1], "the agent once, the command once")

        let card = hoverCardText(for: waiting, now: start, layout: .standard)
        XCTAssertTrue(card.contains("waiting on 1 subagent"))
        XCTAssertTrue(card.contains("still running in the background: 1 shell command"))
        XCTAssertFalse(card.contains("background: 1 subagent"), "said once, by the line that has a symbol")
    }

    func testARowWithNothingRunningSaysNothingAboutIt() {
        var completed = testSession(phase: .completed, lastObservedAt: start)
        completed.backgroundWork = []

        XCTAssertEqual(activityCounts(for: completed).count, 0)
        XCTAssertFalse(hoverCardText(for: completed, now: start, layout: .standard).contains("in the background"))
    }

    // MARK: - Through the engine, the way a live session arrives

    /// The rows above are built from fixtures, and a fixture can hold a shape the engine
    /// never produces. These two are driven by the hooks themselves.
    ///
    /// The shape in question is the empty list. A turn starting clears what the last one left
    /// running, and that clearing used to be an empty list rather than nothing at all — which
    /// a row reads as the session saying "nothing is running". So between `UserPromptSubmit`
    /// and the `Stop` that reports one, the background shell was counted for nobody: not for
    /// an old sender, not for a new one.
    func testABackgroundCommandIsCountedWhileTheTurnThatStartedItRunsOn() throws {
        var engine = SessionStateEngine()
        _ = try engine.ingest(try hook("SessionStart"))
        _ = try engine.ingest(try hook("UserPromptSubmit"))

        let working = try engine.ingest(try backgroundShellCall())

        XCTAssertEqual(activityCounts(for: working).map(\.kind), [.backgroundTask])
        XCTAssertTrue(
            hoverCardText(for: working, now: start, layout: .standard).contains(
                "still running in the background: 1 task"),
            "the card said nothing about the command the turn had just started"
        )
    }

    /// And the `Stop` that ends the turn replaces the app's own count with the session's word
    /// for the kind — the same one command, named rather than merely numbered.
    func testTheStopThatEndsTheTurnNamesTheCommandItLeftRunning() throws {
        var engine = SessionStateEngine()
        _ = try engine.ingest(try hook("SessionStart"))
        _ = try engine.ingest(try hook("UserPromptSubmit"))
        _ = try engine.ingest(try backgroundShellCall())

        let completed = try engine.ingest(try hook("Stop", backgroundWork: [.shell]))

        XCTAssertEqual(activityCounts(for: completed).map(\.count), [1], "one command, counted once")
        XCTAssertTrue(
            hoverCardText(for: completed, now: start, layout: .standard)
                .contains("still running in the background: 1 shell command")
        )
    }

    private func backgroundShellCall() throws -> EventEnvelope {
        try hook(
            "PreToolUse",
            fields: ["tool_use_id": .string("call"), "tool_name": .string("Bash")],
            toolRunsInBackground: true
        )
    }

    private func hook(
        _ event: String,
        fields: [String: JSONValue] = [:],
        toolRunsInBackground: Bool? = nil,
        backgroundWork: [BackgroundWorkKind]? = nil
    ) throws -> EventEnvelope {
        var payload = fields
        payload["session_id"] = .string("id_session")
        return try HookEventNormalizer.normalize(
            source: .claude,
            declaredEvent: event,
            payload: .object(payload),
            observedAt: start,
            toolRunsInBackground: toolRunsInBackground,
            backgroundWork: backgroundWork
        )
    }
}
