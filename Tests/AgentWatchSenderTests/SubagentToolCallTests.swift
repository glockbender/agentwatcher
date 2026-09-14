import AgentWatchCore
import XCTest

@testable import AgentWatchSender

/// A subagent's hooks carry the parent session's identifier, so its tool calls would be
/// counted as the session's own work — and nothing could ever close them, because their
/// results are written to a file the app deliberately never reads. They are stopped here,
/// in the one process that still knows which file the call was writing to.
final class SubagentToolCallTests: XCTestCase {
    private let sessionTranscript =
        "/Users/someone/.claude/projects/-Users-someone-agent-watch/bfe119e1-b5de-45e1-9035-d58c671803d0.jsonl"
    private let subagentTranscript =
        "/Users/someone/.claude/projects/-Users-someone-agent-watch/bfe119e1-b5de-45e1-9035-d58c671803d0"
        + "/subagents/agent-a71650382616bb2f8.jsonl"

    func testAToolCallInsideASubagentIsWithheld() {
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"] {
            XCTAssertTrue(
                SubagentToolCall.fired(declaredEvent: event, payload: payload(transcript: subagentTranscript)),
                "\(event) from inside a subagent is not the session's own work"
            )
        }
    }

    func testTheSessionsOwnToolCallIsSent() {
        XCTAssertFalse(
            SubagentToolCall.fired(declaredEvent: "PreToolUse", payload: payload(transcript: sessionTranscript))
        )
    }

    /// What the row is left with, and the whole reason withholding is enough: the subagent
    /// itself is announced by events that are not tool calls.
    func testTheSubagentItselfIsStillAnnounced() {
        for event in ["SubagentStart", "SubagentStop"] {
            XCTAssertFalse(
                SubagentToolCall.fired(declaredEvent: event, payload: payload(transcript: subagentTranscript)),
                "\(event) is how the row says a subagent is running at all"
            )
        }
    }

    /// A person asked to approve a call is a session waiting for a person, whoever made the
    /// call. That is true of the session, so it goes.
    func testAPermissionRequestFromASubagentStillCounts() {
        XCTAssertFalse(
            SubagentToolCall.fired(declaredEvent: "PermissionRequest", payload: payload(transcript: subagentTranscript))
        )
    }

    /// Fail-open, like every other judgement in the sender: withholding an event on a guess
    /// would lose work the session really is doing.
    func testAPayloadThatCannotBeJudgedIsSent() {
        XCTAssertFalse(SubagentToolCall.fired(declaredEvent: "PreToolUse", payload: .object([:])))
        XCTAssertFalse(SubagentToolCall.fired(declaredEvent: "PreToolUse", payload: .string("not an object")))
    }

    /// Either half of the shape is enough on its own, so renaming one of them degrades to
    /// "not a subagent" rather than to a wrong answer.
    func testEitherHalfOfTheShapeIsEnough() {
        XCTAssertTrue(SubagentToolCall.isSubagentTranscript("/tmp/whatever/agent-abc.jsonl"))
        XCTAssertTrue(SubagentToolCall.isSubagentTranscript("/tmp/subagents/renamed.jsonl"))
        XCTAssertFalse(SubagentToolCall.isSubagentTranscript("/tmp/projects/p/session.jsonl"))
    }

    private func payload(transcript: String) -> JSONValue {
        .object(["session_id": .string("bfe119e1"), "transcript_path": .string(transcript)])
    }
}
