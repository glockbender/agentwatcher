import Foundation
import XCTest

@testable import AgentWatchCore

final class HookModeTransitionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testEveryExplicitHookModeReachesTheRunningSession() throws {
        var engine = SessionStateEngine()
        XCTAssertEqual(try engine.ingest(hook("UserPromptSubmit", mode: "plan")).phase, .planning)

        let standard = try engine.ingest(hook("PreToolUse", mode: "default"))
        XCTAssertEqual(standard.mode, .standard)
        XCTAssertEqual(standard.phase, .executing)

        let planning = try engine.ingest(hook("PreToolUse", mode: "plan"))
        XCTAssertEqual(planning.mode, .plan)
        XCTAssertEqual(planning.phase, .planning)

        let unstated = try engine.ingest(hook("PostToolUse"))
        XCTAssertEqual(unstated.mode, .plan)
        XCTAssertEqual(unstated.phase, .planning)
    }

    func testModeChangesWhileWaitingWithoutAnsweringTheWrongCall() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit", mode: "plan"))
        try engine.ingest(hook("PreToolUse", activityID: "awaited"))
        try engine.ingest(hook("PermissionRequest", activityID: "awaited"))

        let waiting = try engine.ingest(hook("PostToolUse", mode: "default", activityID: "unrelated"))
        XCTAssertEqual(waiting.mode, .standard)
        XCTAssertEqual(waiting.phase, .waitingForUser)
        XCTAssertEqual(waiting.userInputRequestKind, .approval)

        let answered = try engine.ingest(hook("PostToolUse", activityID: "awaited"))
        XCTAssertEqual(answered.mode, .standard)
        XCTAssertEqual(answered.phase, .executing)
    }

    func testALateModeDoesNotReopenAClosedSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(hook("UserPromptSubmit", mode: "plan"))
        try engine.ingest(hook("SessionEnd"))
        let late = try engine.ingest(hook("PreToolUse", mode: "default"))
        XCTAssertEqual(late.phase, .sessionClosed)
        XCTAssertEqual(late.mode, .plan)
    }

    private func hook(_ event: String, mode: String? = nil, activityID: String = "call") throws -> EventEnvelope {
        var fields: [String: JSONValue] = [
            "session_id": .string("session"),
            "tool_use_id": .string(activityID),
            "tool_name": .string("Bash"),
        ]
        if let mode { fields["permission_mode"] = .string(mode) }
        return try HookIngressProcessor.normalize(
            HookIngressRequest(source: .claude, declaredEvent: event, payload: .object(fields)),
            observedAt: now
        )
    }
}
