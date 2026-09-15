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
}
