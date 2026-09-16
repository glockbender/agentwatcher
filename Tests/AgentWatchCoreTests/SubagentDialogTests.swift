import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// A permission dialog that belongs to a subagent, from the raw hooks to the row's phase.
///
/// The reducer is covered on its own in `SessionReducerTests`; what this file adds is the
/// path between — that `agent_id` survives redaction, reaches the activity as its parent,
/// and so lets the wait tell one agent's events from another's. The sequence is the one
/// measured on the evening the row was wrong.
final class SubagentDialogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 3_000)

    func testASubagentsDialogSurvivesEverythingTheRestOfTheSessionDoes() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-a"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-b"))
        try engine.ingest(hook("PreToolUse", agentID: "reviewer-a", toolUseID: "a-bash"))

        let asked = try engine.ingest(hook("PermissionRequest", agentID: "reviewer-a"))
        XCTAssertEqual(asked.phase, .waitingForUser)
        XCTAssertEqual(asked.userInputRequestKind, .approval)

        let elsewhere = try engine.ingest(hook("PreToolUse", agentID: "reviewer-b", toolUseID: "b-bash"))
        XCTAssertEqual(
            elsewhere.phase,
            .waitingForUser,
            "the other subagent's call is not an answer to this dialog"
        )

        let mainTurnEnded = try engine.ingest(hook("Stop"))
        XCTAssertEqual(mainTurnEnded.phase, .waitingForUser, "`Stop` belongs to the main thread")

        let nextPrompt = try engine.ingest(hook("UserPromptSubmit"))
        XCTAssertEqual(nextPrompt.phase, .waitingForUser, "so does the next prompt")

        let answered = try engine.ingest(hook("PostToolUse", agentID: "reviewer-a", toolUseID: "a-bash"))
        XCTAssertEqual(answered.phase, .executing, "the call the dialog was about has run")
        XCTAssertFalse(answered.isAwaitingAnswer)
    }

    /// Two subagents asking at once, which Claude Code allows: measured on 2.1.272, two
    /// `PermissionRequest` hooks arrived a second apart with neither of them answered.
    /// Answering one of them leaves the other still on screen, so the session is still
    /// waiting for its person.
    func testOneAnswerDoesNotEndASecondSubagentsDialog() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-a"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-b"))
        try engine.ingest(hook("PreToolUse", agentID: "reviewer-a", toolUseID: "a-bash"))
        try engine.ingest(hook("PermissionRequest", agentID: "reviewer-a"))
        try engine.ingest(hook("PreToolUse", agentID: "reviewer-b", toolUseID: "b-bash"))
        try engine.ingest(hook("PermissionRequest", agentID: "reviewer-b"))

        let oneAnswered = try engine.ingest(hook("PostToolUse", agentID: "reviewer-b", toolUseID: "b-bash"))

        XCTAssertEqual(
            oneAnswered.phase,
            .waitingForUser,
            "the first subagent's dialog is still unanswered"
        )
    }

    /// The row names one question, and once that one is answered it has to name the next.
    ///
    /// Two dialogs of different kinds is the case that shows it: an approval answered while
    /// a choice is still on screen used to leave the row reading "approval needed", which is
    /// the wrong instruction to give a person.
    func testTheRowNamesWhicheverQuestionIsStillOpen() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-a"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-b"))
        try engine.ingest(hook("PreToolUse", agentID: "reviewer-a", toolUseID: "a-bash"))
        try engine.ingest(hook("PermissionRequest", agentID: "reviewer-a"))

        let both = try engine.ingest(
            hook("PreToolUse", agentID: "reviewer-b", toolUseID: "b-question", tool: "AskUserQuestion")
        )
        XCTAssertEqual(
            both.userInputRequestKind,
            .approval,
            "the oldest question is the one the row names, and a new one does not push it aside"
        )

        let approvalAnswered = try engine.ingest(hook("PostToolUse", agentID: "reviewer-a", toolUseID: "a-bash"))

        XCTAssertEqual(approvalAnswered.phase, .waitingForUser)
        XCTAssertEqual(approvalAnswered.userInputRequestKind, .selection, "the choice is what is left")
    }

    /// The mirror of the test above, and the one that makes it mean anything: the *asked*
    /// agent issuing a new call does end the wait, because it could only have been issued
    /// after an answer. Without it, a rule that simply never let a start end a subagent's
    /// wait would pass the test above just as well.
    func testTheAskedSubagentsOwnNextCallDoesEndItsWait() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-a"))
        try engine.ingest(hook("PreToolUse", agentID: "reviewer-a", toolUseID: "a-bash"))
        try engine.ingest(hook("PermissionRequest", agentID: "reviewer-a"))

        let resumed = try engine.ingest(hook("PreToolUse", agentID: "reviewer-a", toolUseID: "a-next"))

        XCTAssertEqual(resumed.phase, .executing, "the agent that was asked has gone on working")
        XCTAssertFalse(resumed.isAwaitingAnswer)
    }

    /// The degraded path, and the same bug hiding on it. With no awaited call recorded, any
    /// ending has to be taken as the answer — a rule written for the main thread, where
    /// there is only one agent whose endings could arrive. For a subagent's dialog it hands
    /// the answer back to whichever other subagent finished next.
    ///
    /// A dialog reaches this state whenever the call's own `PreToolUse` never arrived: hooks
    /// are fail-open, so the app being down for a moment is a designed-for condition.
    func testASubagentsDialogWithNoKnownCallIsStillNotAnsweredByAnotherAgent() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-a"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-b"))
        // No `PreToolUse` for the call being asked about — that is the whole point.
        let asked = try engine.ingest(hook("PermissionRequest", agentID: "reviewer-a"))
        XCTAssertNil(asked.unansweredDialogs.first?.activityID, "nothing was heard about the call itself")

        try engine.ingest(hook("PreToolUse", agentID: "reviewer-b", toolUseID: "b-bash"))
        let elsewhere = try engine.ingest(hook("PostToolUse", agentID: "reviewer-b", toolUseID: "b-bash"))

        XCTAssertEqual(elsewhere.phase, .waitingForUser, "another agent's call finishing answers nothing")

        let stopped = try engine.ingest(hook("SubagentStop", agentID: "reviewer-a"))
        XCTAssertNotEqual(stopped.phase, .waitingForUser, "its own end still releases it")
    }

    /// The main thread's own dialog keeps behaving as it always did — which is what makes
    /// this change safe for Codex, whose hooks never carry an agent at all.
    func testTheMainThreadsOwnDialogStillEndsAtTheNextCall() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("PreToolUse", toolUseID: "main-bash"))

        let asked = try engine.ingest(hook("PermissionRequest"))
        XCTAssertEqual(asked.phase, .waitingForUser)

        let next = try engine.ingest(hook("PreToolUse", toolUseID: "main-next"))
        XCTAssertEqual(next.phase, .executing)
        XCTAssertFalse(next.isAwaitingAnswer)
    }

    /// A dialog dismissed rather than answered leaves no ending for the call it was about.
    /// The subagent's own end is what releases it — and until this change there was nothing
    /// left to, because the main thread's events no longer speak for a child.
    func testASubagentEndingReleasesItsOwnUnansweredDialog() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit"))
        try engine.ingest(hook("SubagentStart", agentID: "reviewer-a"))
        try engine.ingest(hook("PreToolUse", agentID: "reviewer-a", toolUseID: "a-bash"))
        try engine.ingest(hook("PermissionRequest", agentID: "reviewer-a"))

        let stopped = try engine.ingest(hook("SubagentStop", agentID: "reviewer-a"))

        XCTAssertNotEqual(stopped.phase, .waitingForUser)
        XCTAssertFalse(stopped.isAwaitingAnswer)
    }

    /// Through the ingress, so `agent_id` goes through the redaction the socket applies.
    private func hook(
        _ event: String,
        agentID: String? = nil,
        toolUseID: String? = nil,
        tool: String = "Bash"
    ) throws -> EventEnvelope {
        var payload: [String: JSONValue] = [
            "session_id": .string("session"),
            "permission_mode": .string("default"),
        ]
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
