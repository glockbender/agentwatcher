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
            hoverCardText(for: completed, now: start)
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

        let card = hoverCardText(for: completed, now: start)

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
            hoverCardText(for: waiting, now: start).contains("still running in the background: 1 task")
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

        let card = hoverCardText(for: waiting, now: start)
        XCTAssertTrue(card.contains("waiting on 1 subagent"))
        XCTAssertTrue(card.contains("still running in the background: 1 shell command"))
        XCTAssertFalse(card.contains("background: 1 subagent"), "said once, by the line that has a symbol")
    }

    func testARowWithNothingRunningSaysNothingAboutIt() {
        var completed = testSession(phase: .completed, lastObservedAt: start)
        completed.backgroundWork = []

        XCTAssertEqual(activityCounts(for: completed).count, 0)
        XCTAssertFalse(hoverCardText(for: completed, now: start).contains("in the background"))
    }
}
