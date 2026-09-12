import Foundation
import XCTest

@testable import AgentWatchCore

final class TranscriptLifecycleProvenanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let marker = "[Request interrupted by user]"
    private let notification =
        "<task-notification>\n<task-id>task-1</task-id>\n<tool-use-id>call-1</tool-use-id>\n<status>completed</status>\n</task-notification>"

    func testAssistantExplanationsAndUserQuotationsNeverBecomeLifecycleFacts() throws {
        for role in ["assistant", "user"] {
            for text in [marker, marker + " is the diagnostic string.", "Quoted: " + marker, notification] {
                let facts = try read(role: role, content: [["type": "text", "text": text]])
                XCTAssertTrue(facts.isEmpty, "\(role): \(text)")
                XCTAssertTrue(try read(role: role, content: text).isEmpty)
            }
        }
    }

    func testAnInterruptionRequiresTheExactServiceRecord() throws {
        for text in [marker, "[Request interrupted by user for tool use]"] {
            XCTAssertEqual(
                try read(
                    role: "user", content: [["type": "text", "text": text]],
                    metadata: ["interruptedMessageId": "message-1"]),
                [.turnInterrupted(at: now)]
            )
        }
        for text in [marker + " quoted", "> " + marker, "[Request interrupted by user unexpectedly]"] {
            XCTAssertTrue(
                try read(
                    role: "user", content: [["type": "text", "text": text]],
                    metadata: ["interruptedMessageId": "message-1"]
                ).isEmpty)
        }
        XCTAssertTrue(
            try read(
                role: "assistant", content: [["type": "text", "text": marker]],
                metadata: ["interruptedMessageId": "message-1"]
            ).isEmpty)
        XCTAssertTrue(
            try read(
                role: "user", content: [["type": "text", "text": marker], ["type": "text", "text": "Explanation"]],
                metadata: ["interruptedMessageId": "message-1"]
            ).isEmpty)
    }

    func testOnlyASystemTaskNotificationCanEndBackgroundWork() throws {
        let metadata: [String: Any] = ["promptSource": "system", "origin": ["kind": "task-notification"]]
        XCTAssertEqual(
            try read(role: "user", content: notification, metadata: metadata),
            [.workEnded(activityID: HookCaptureRedactor.label(forRawIdentifier: "call-1"), at: now)]
        )
        XCTAssertTrue(try read(role: "assistant", content: notification, metadata: metadata).isEmpty)
        XCTAssertTrue(try read(role: "user", content: notification, metadata: ["promptSource": "system"]).isEmpty)
        XCTAssertTrue(
            try read(role: "user", content: notification, metadata: ["origin": ["kind": "task-notification"]]).isEmpty)
        XCTAssertTrue(try read(role: "user", content: "Example: " + notification, metadata: metadata).isEmpty)
        XCTAssertTrue(
            try read(
                role: "user", content: notification.replacingOccurrences(of: "completed", with: "running"),
                metadata: metadata
            ).isEmpty)
    }

    func testAnAssistantExplanationLeavesTheLiveSessionWorking() throws {
        var engine = SessionStateEngine()
        let snapshot = try engine.ingest(
            EventEnvelope(source: .claude, sessionID: "session", observedAt: now, kind: .turnStarted))
        for fact in try read(
            role: "assistant", content: [["type": "text", "text": marker + " is the diagnostic string."]])
        {
            engine.apply(fact, toSessionWithID: snapshot.id)
        }
        XCTAssertEqual(engine.snapshots[snapshot.id]?.phase, .executing)
    }

    func testAFailedBackgroundLaunchEndsThroughTheTranscriptWithoutAFailureHook() throws {
        var engine = SessionStateEngine()
        let session = try engine.ingest(
            EventEnvelope(source: .claude, sessionID: "session", observedAt: now, kind: .turnStarted))
        let callID = HookCaptureRedactor.label(forRawIdentifier: "call-1")
        try engine.ingest(
            EventEnvelope(
                source: .claude, sessionID: "session", activityID: callID, observedAt: now, kind: .activityStarted,
                activityKind: .shell, activityOutlivesTurn: true, activityOutlivesItsCall: true))
        let facts = try read(
            role: "user", content: [["type": "tool_result", "tool_use_id": "call-1", "is_error": true]])
        XCTAssertEqual(facts, [.callFailed(activityID: callID, at: now)])
        for fact in facts { engine.apply(fact, toSessionWithID: session.id) }
        let stopped = try engine.ingest(
            EventEnvelope(source: .claude, sessionID: "session", observedAt: now + 1, kind: .turnCompleted))
        XCTAssertTrue(stopped.activities.isEmpty)
        XCTAssertEqual(stopped.phase, .completed)
    }

    private func read(role: String, content: Any, metadata: [String: Any] = [:]) throws -> [TranscriptFact] {
        var record = metadata
        record["type"] = role
        record["message"] = ["role": role, "content": content]
        var bytes = try JSONSerialization.data(withJSONObject: record)
        bytes.append(0x0A)
        return try TranscriptReader.read(increment: bytes, source: .claude, observedAt: now).facts
    }
}
