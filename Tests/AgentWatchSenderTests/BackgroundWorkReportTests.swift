import AgentWatchCore
import XCTest

@testable import AgentWatchSender

/// What the sender lifts out of `Stop`'s own `background_tasks`.
///
/// Measured on Claude Code 2.1.272 with a `Stop` hook that wrote its payload to a file: a
/// command the agent asked to run in the background and a command Claude Code moved there
/// itself after its timeout both arrive in this array, described alike. See
/// `docs/measurements.md`.
final class BackgroundWorkReportTests: XCTestCase {
    func testStopReportsTheKindOfEachTaskStillRunning() {
        let payload: JSONValue = .object([
            "session_id": .string("s1"),
            "hook_event_name": .string("Stop"),
            "background_tasks": .array([
                .object([
                    "id": .string("b2x71w2yx"),
                    "type": .string("shell"),
                    "status": .string("running"),
                    "description": .string("Wait for the review round to finish"),
                    "command": .string("python3 review.py --mr 67 wait"),
                ])
            ]),
        ])

        XCTAssertEqual(RedactedHookIngressRequest.backgroundWork(in: payload), [.shell])
    }

    func testAnEmptyArrayIsReportedAsNoBackgroundWork() {
        let payload: JSONValue = .object([
            "session_id": .string("s1"),
            "background_tasks": .array([]),
        ])

        XCTAssertEqual(RedactedHookIngressRequest.backgroundWork(in: payload), [])
    }

    /// A hook that says nothing about background work is not a hook saying there is none:
    /// every event other than `Stop` carries no such field, and reading its absence as
    /// "nothing is running" would clear the row on the next `PreToolUse`.
    func testAHookThatNeverMentionsBackgroundWorkReportsNothingAtAll() {
        let payload: JSONValue = .object(["session_id": .string("s1")])

        XCTAssertNil(RedactedHookIngressRequest.backgroundWork(in: payload))
    }

    /// The kind is an open list on Claude Code's side — its own schema says the label "falls
    /// back to the raw discriminant for unknown types" — so a word this app has never seen is
    /// the expected case, not a malformed one. It becomes `other`: the word is not carried
    /// into a row unread, and the one fact worth having, that something is still running, is
    /// not thrown away with it.
    func testAKindThisAppHasNoWordForIsStillCounted() {
        let payload: JSONValue = .object([
            "background_tasks": .array([
                .object(["type": .string("shell")]),
                .object(["type": .string("holodeck")]),
            ])
        ])

        XCTAssertEqual(RedactedHookIngressRequest.backgroundWork(in: payload), [.shell, .other])
    }

    /// And an entry shaped like nothing this expects is still an entry. Anything running as
    /// this user can write to the socket, so the shape is not promised — but a task the sender
    /// cannot describe is a task, and dropping it would under-report the one thing this field
    /// is for.
    func testAnEntryWithNothingToReadIsCountedAsATaskAllTheSame() {
        let payload: JSONValue = .object([
            "background_tasks": .array([
                .object(["status": .string("running")]),
                .string("not an object at all"),
            ])
        ])

        XCTAssertEqual(RedactedHookIngressRequest.backgroundWork(in: payload), [.other, .other])
    }

    /// Both spellings, like every other field the sender reads: the payload arrives as the
    /// agent writes it, and this app does not get to choose the case.
    func testTheCamelCaseSpellingIsReadToo() {
        let payload: JSONValue = .object([
            "backgroundTasks": .array([.object(["type": .string("monitor")])])
        ])

        XCTAssertEqual(RedactedHookIngressRequest.backgroundWork(in: payload), [.monitor])
    }
}
