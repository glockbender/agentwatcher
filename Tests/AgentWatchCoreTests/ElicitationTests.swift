import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// An MCP server asking the person something, from the raw hooks to the row's phase.
///
/// The order is the one measured on Claude Code 2.1.293 with a server whose tool asks a
/// question: `PreToolUse` for the server's tool, `Elicitation`, `ElicitationResult`, then the
/// tool's own `PostToolUse`. Before the two hooks were asked for, the row read `working` with
/// a wrench for the whole time the person was being asked.
final class ElicitationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000)

    func testTheRowWaitsForThePersonWhileAnMCPServerAsks() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("PreToolUse", toolUseID: "mcp-call", tool: "mcp__probe__ask"))

        let asked = try engine.ingest(hook("Elicitation"))
        XCTAssertEqual(asked.phase, .waitingForUser)
        XCTAssertEqual(asked.userInputRequestKind, .elicitation)
        XCTAssertEqual(asked.activities.map(\.kind), [.tool], "the question is not a call of its own")

        let answered = try engine.ingest(hook("ElicitationResult"))
        XCTAssertEqual(answered.phase, .executing, "the server's tool runs on with the answer")
        XCTAssertFalse(answered.isAwaitingAnswer)
        XCTAssertEqual(answered.activities.map(\.kind), [.tool])

        let returned = try engine.ingest(hook("PostToolUse", toolUseID: "mcp-call", tool: "mcp__probe__ask"))
        XCTAssertTrue(returned.activities.isEmpty)
    }

    /// The answer names no agent and no call, so it must end the server's question and
    /// nothing else: a subagent's permission dialog open at the same time is still on screen.
    func testTheServersAnswerLeavesASubagentsDialogOpen() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer"))
        try engine.ingest(hook("PreToolUse", agentID: "reviewer", toolUseID: "reviewer-bash"))
        try engine.ingest(hook("PermissionRequest", agentID: "reviewer"))
        try engine.ingest(hook("PreToolUse", toolUseID: "mcp-call", tool: "mcp__probe__ask"))
        try engine.ingest(hook("Elicitation"))

        let answered = try engine.ingest(hook("ElicitationResult"))

        XCTAssertEqual(answered.phase, .waitingForUser)
        XCTAssertEqual(answered.userInputRequestKind, .approval)
        XCTAssertEqual(answered.unansweredDialogs.count, 1)
        XCTAssertNotNil(answered.unansweredDialogs.first?.agentID, "the one left is the subagent's")
    }

    /// Another hook can answer the question for the person, and then Claude Code sends no
    /// `ElicitationResult` — read in its code, 2.1.293. The end of the turn still ends the wait.
    func testAQuestionNothingReportsAnsweredEndsWithTheTurn() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("PreToolUse", toolUseID: "mcp-call", tool: "mcp__probe__ask"))
        try engine.ingest(hook("Elicitation"))

        let ended = try engine.ingest(hook("Stop"))

        XCTAssertEqual(ended.phase, .completed)
        XCTAssertFalse(ended.isAwaitingAnswer)
    }

    /// Through the ingress, so the payload goes through the redaction the socket applies.
    private func hook(
        _ event: String,
        agentID: String? = nil,
        toolUseID: String? = nil,
        tool: String = "Bash"
    ) throws -> EventEnvelope {
        var payload: [String: JSONValue] = ["session_id": .string("session")]
        if let agentID {
            payload["agent_id"] = .string(agentID)
        }
        if let toolUseID {
            payload["tool_use_id"] = .string(toolUseID)
            payload["tool_name"] = .string(tool)
        }
        return try HookIngressProcessor.normalize(
            HookIngressRequest(source: .claude, declaredEvent: event, payload: .object(payload)),
            observedAt: start
        )
    }
}
