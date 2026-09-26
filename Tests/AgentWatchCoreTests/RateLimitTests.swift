import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

final class RateLimitTests: XCTestCase {
    func testRateLimitArrivesAsInactivityThroughBothRedactions() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let captured = try HookCaptureRedactor.redact(
            declaredEvent: "StopFailure",
            payload: .object([
                "session_id": .string("limited-session"),
                "error": .string("rate_limit"),
            ])
        )
        let event = try HookIngressProcessor.normalize(
            HookIngressRequest(source: .claude, declaredEvent: captured.declaredEvent, payload: captured.payload),
            observedAt: now
        )
        var engine = SessionStateEngine()
        let snapshot = try engine.ingest(event)
        XCTAssertEqual(snapshot.phase, .rateLimited)
        XCTAssertTrue(snapshot.hasWorked)
        XCTAssertEqual(snapshot.phase.attention, .quiet)
        XCTAssertEqual(SessionBlock.of(snapshot, now: now), .inactive)
    }

    func testOtherErrorsAndMalformedReasonsRemainFailures() throws {
        for reason: JSONValue in [
            .string("authentication_failed"), .string("server_error"), .string("billing_error"),
            .string("unknown"), .string("You've hit your limit"), .null, .number(429),
            .object(["error": .string("rate_limit")]),
        ] {
            let event = try hook("StopFailure", fields: ["error": reason])
            var engine = SessionStateEngine()
            XCTAssertEqual(try engine.ingest(event).phase, .failed, "\(reason)")
        }
        var engine = SessionStateEngine()
        XCTAssertEqual(try engine.ingest(hook("StopFailure")).phase, .failed)
    }

    func testTelemetryDoesNotClearTheLimitButANewPromptDoes() throws {
        var engine = SessionStateEngine()
        _ = try engine.ingest(hook("UserPromptSubmit"))
        _ = try engine.ingest(hook("StopFailure", fields: ["error": .string("rate_limit")], seconds: 1))
        let telemetry = try engine.ingest(hook("StatusLine", seconds: 2))
        XCTAssertEqual(telemetry.phase, .rateLimited)
        let resumed = try engine.ingest(hook("UserPromptSubmit", seconds: 3))
        XCTAssertEqual(resumed.phase, .executing)
        XCTAssertEqual(SessionBlock.of(resumed, now: resumed.lastObservedAt), .active)
    }

    func testLimitEndsForegroundCallsButKeepsIndependentWork() {
        let now = Date(timeIntervalSince1970: 1000)
        let shell = SessionActivity(id: "shell", kind: .shell, startedAt: now)
        let child = SessionActivity(id: "child", kind: .subagent, startedAt: now, outlivesTurn: true)
        var session = testSession(phase: .executing, activities: [shell, child], lastObservedAt: now)
        session.backgroundWork = [.shell]
        let limited = SessionReducer.reduce(session, event: .rateLimited(at: now + 1))
        XCTAssertEqual(limited.phase, .rateLimited)
        XCTAssertEqual(limited.activities, [child])
        XCTAssertEqual(limited.backgroundWork, [.shell])
        let settled = SessionReducer.reduce(limited, event: .activityCompleted(id: "child", at: now + 2))
        XCTAssertEqual(settled.phase, .rateLimited, "a child finishing does not resume the main turn")
        XCTAssertTrue(settled.activities.isEmpty)
    }

    func testLimitDoesNotAnswerASubagentsDialog() {
        let now = Date(timeIntervalSince1970: 1000)
        var session = testSession(phase: .waitingForUser, lastObservedAt: now)
        let child = AwaitedDialog(agentID: "child", activityID: "tool", kind: .approval)
        session.setAwaitedDialogs([
            AwaitedDialog(agentID: nil, activityID: nil, kind: .selection), child,
        ])
        let limited = SessionReducer.reduce(session, event: .rateLimited(at: now + 1))
        XCTAssertEqual(limited.phase, .waitingForUser)
        XCTAssertEqual(limited.unansweredDialogs, [child])
        for answer in [
            SessionEvent.activityCompleted(id: "child", at: now + 2),
            .activityCompleted(id: "tool", at: now + 2),
            .userInputResolved(at: now + 2),
        ] {
            let settled = SessionReducer.reduce(limited, event: answer)
            XCTAssertEqual(settled.phase, .rateLimited, "\(answer) must not resume the foreground turn")
            XCTAssertTrue(settled.unansweredDialogs.isEmpty)
        }
        let resumed = SessionReducer.reduce(limited, event: .turnStarted(mode: .standard, at: now + 2))
        let answered = SessionReducer.reduce(resumed, event: .userInputResolved(at: now + 3))
        XCTAssertEqual(answered.phase, .executing, "a new foreground turn releases the limit")
    }

    func testOnlyForegroundWorkReleasesALimit() {
        let now = Date(timeIntervalSince1970: 1000)
        let limited = SessionReducer.reduce(
            testSession(phase: .executing, lastObservedAt: now),
            event: .rateLimited(at: now + 1))
        for activity in [
            SessionActivity(id: "child-tool", kind: .tool, startedAt: now, parentID: "child"),
            SessionActivity(id: "child", kind: .subagent, startedAt: now, outlivesTurn: true),
        ] {
            let running = SessionReducer.reduce(limited, event: .activityStarted(activity, at: now + 2))
            XCTAssertEqual(running.phase, .rateLimited)
        }
        let tool = SessionActivity(id: "main-tool", kind: .tool, startedAt: now)
        let resumed = SessionReducer.reduce(limited, event: .activityStarted(tool, at: now + 2))
        XCTAssertEqual(resumed.phase, .executing)
        XCTAssertNil(resumed.rateLimitReachedAt)
    }

    func testLimitClearsTheMainDialogAndSessionCanClose() throws {
        var engine = SessionStateEngine()
        _ = try engine.ingest(hook("PermissionRequest"))
        let limited = try engine.ingest(hook("StopFailure", fields: ["error": .string("rate_limit")], seconds: 1))
        XCTAssertEqual(limited.phase, .rateLimited)
        XCTAssertTrue(limited.unansweredDialogs.isEmpty)
        let closed = try engine.ingest(hook("SessionEnd", seconds: 2))
        XCTAssertEqual(closed.phase, .sessionClosed)
        let late = try engine.ingest(hook("StopFailure", fields: ["error": .string("rate_limit")], seconds: 3))
        XCTAssertEqual(late.phase, .sessionClosed)
    }

    func testLimitDoesNotBecomeStaleWhileWaiting() throws {
        var engine = SessionStateEngine()
        let limited = try engine.ingest(hook("StopFailure", fields: ["error": .string("rate_limit")]))
        XCTAssertEqual(SessionFreshnessEvaluator.evaluate(limited, now: limited.lastObservedAt + 3600), .current)
        XCTAssertTrue(SessionSilence.isExpected(limited))
        XCTAssertEqual(
            SessionAttentionCounts(sessions: [limited]),
            SessionAttentionCounts(needsPerson: 0, working: 0, done: 0, quiet: 1))
    }

    func testAnotherEndingOrLossOfStateClearsTheLimit() {
        let now = Date(timeIntervalSince1970: 1000)
        let limited = SessionReducer.reduce(
            testSession(phase: .executing, lastObservedAt: now),
            event: .rateLimited(at: now + 1))
        for event in [
            SessionEvent.turnCompleted(at: now + 2), .turnInterrupted(at: now + 2),
            .failed(at: now + 2), .sessionClosed(at: now + 2), .terminalClosed,
            .disconnected(at: now + 2), .sessionStarted(mode: nil, at: now + 2),
        ] {
            let ended = SessionReducer.reduce(limited, event: event)
            XCTAssertNil(ended.rateLimitReachedAt, "\(event)")
            XCTAssertNotEqual(ended.phase, .rateLimited)
        }
        let remembered = SessionHistory.remembered(limited)
        XCTAssertNil(remembered.rateLimitReachedAt)
        XCTAssertEqual(remembered.phase, .disconnected)
    }

    private func hook(
        _ name: String, fields: [String: JSONValue] = [:], seconds: TimeInterval = 0
    ) throws -> EventEnvelope {
        var payload = fields
        payload["session_id"] = .string("limited-session")
        let captured = try HookCaptureRedactor.redact(declaredEvent: name, payload: .object(payload))
        return try HookIngressProcessor.normalize(
            HookIngressRequest(source: .claude, declaredEvent: captured.declaredEvent, payload: captured.payload),
            observedAt: Date(timeIntervalSince1970: 1000 + seconds)
        )
    }

}
