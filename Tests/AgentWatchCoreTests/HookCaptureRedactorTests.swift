import Foundation
import XCTest

@testable import AgentWatchCore

final class HookCaptureRedactorTests: XCTestCase {
    /// Pins the two ways an identifier can reach a snapshot to the same string.
    ///
    /// One way is the socket: the hook process redacts, the app redacts again because it does
    /// not trust whatever connected to it. The other is `label(forRawIdentifier:)`, used by
    /// anything reading a raw identifier off disk. If the app-side pass is ever removed as a
    /// redundant second hash, every correlation made from a transcript stops matching — and
    /// it fails as "found nothing", which reads like a broken transcript rather than a code
    /// change. This test is what turns that into a red build.
    func testAnIdentifierOffDiskLandsOnTheSameLabelAsOneOffTheSocket() throws {
        let raw = "toolu_01CePmLevgH5XrWyBCgawVe9"

        let fromTheHook = try HookCaptureRedactor.redact(
            declaredEvent: "PostToolUse",
            payload: .object(["tool_use_id": .string(raw)])
        )
        let fromTheApp = try HookCaptureRedactor.redact(
            declaredEvent: fromTheHook.declaredEvent,
            payload: fromTheHook.payload
        )

        guard case let .object(fields) = fromTheApp.payload else {
            return XCTFail("Expected an object payload")
        }
        XCTAssertEqual(
            fields["tool_use_id"],
            .string(HookCaptureRedactor.label(forRawIdentifier: raw)),
            "a transcript reader could correlate nothing if these two drifted apart"
        )
    }

    func testRedactsSensitiveContentAndKeepsSafeTechnicalValues() throws {
        let input = try XCTUnwrap(
            """
            {
              "session_id": "session-secret",
              "hook_event_name": "PreToolUse",
              "tool_name": "Bash",
              "tool_input": {"command": "cat .env"},
              "tool_response": {"stdout": "secret result"},
              "toolInput": {"command": "also secret"},
              "input_tokens": 42,
              "this-key-contains-arbitrary-user-text": "do not retain me",
              "user_prompt": "read a secret",
              "permission_mode": "plan",
              "duration_ms": 15,
              "success": true
            }
            """.data(using: .utf8)
        )

        let event = try redacted(declaredEvent: "PreToolUse", input: input)

        XCTAssertEqual(event.declaredEvent, "PreToolUse")
        guard case let .object(payload) = event.payload else {
            return XCTFail("Expected an object payload")
        }

        XCTAssertEqual(payload["hook_event_name"], .string("PreToolUse"))
        XCTAssertEqual(payload["tool_name"], .string("Bash"))
        XCTAssertEqual(payload["tool_input"], .string("<redacted>"))
        XCTAssertEqual(payload["tool_response"], .string("<redacted>"))
        XCTAssertEqual(payload["tool_input"], .string("<redacted>"))
        XCTAssertNil(payload["toolInput"])
        XCTAssertNil(payload["input_tokens"])
        XCTAssertEqual(payload["user_prompt"], .string("<redacted>"))
        XCTAssertEqual(payload["permission_mode"], .string("plan"))
        XCTAssertEqual(payload["duration_ms"], .number(15))
        XCTAssertEqual(payload["success"], .bool(true))
        XCTAssertEqual(payload["redacted_sensitive_field_count"], .number(1))
        XCTAssertEqual(payload["unknown_field_count"], .number(1))
        XCTAssertNil(payload["this-key-contains-arbitrary-user-text"])

        guard case let .string(sessionID)? = payload["session_id"] else {
            return XCTFail("Expected a redacted session identifier")
        }
        XCTAssertTrue(sessionID.hasPrefix("id_"))
        XCTAssertNotEqual(sessionID, "session-secret")
    }

    func testProducesTheSameIdentifierLabelForTheSameRawIdentifier() throws {
        let input = Data("{\"session_id\":\"same-session\"}".utf8)

        let first = try redacted(declaredEvent: "Stop", input: input)
        let second = try redacted(declaredEvent: "Stop", input: input)

        XCTAssertEqual(first.payload, second.payload)
    }

    func testRejectsPayloadsThatAreNotObjectsAndEventsNotOnTheAllowlist() {
        XCTAssertThrowsError(
            try redacted(declaredEvent: "Stop", input: Data("[]".utf8))
        ) { error in
            XCTAssertEqual(error as? HookCaptureError, .expectedJSONObject)
        }

        XCTAssertThrowsError(
            try redacted(declaredEvent: "SensitiveEvent123", input: Data("{}".utf8))
        ) { error in
            XCTAssertEqual(error as? HookCaptureError, .unsupportedDeclaredEvent)
        }
    }

    func testRejectsUnknownEnumLikeValues() throws {
        let input = Data(
            """
            {
              "hook_event_name": "SecretEvent123",
              "tool_name": "SensitiveValue123",
              "permission_mode": "SensitiveMode123"
            }
            """.utf8
        )

        let event = try redacted(declaredEvent: "PreToolUse", input: input)
        guard case let .object(payload) = event.payload else {
            return XCTFail("Expected an object payload")
        }

        XCTAssertEqual(payload["hook_event_name"], .string("<redacted>"))
        XCTAssertEqual(payload["tool_name"], .string("<redacted>"))
        XCTAssertEqual(payload["permission_mode"], .string("<redacted>"))
    }

    func testRedactsUnsupportedTypesForIdentifiersAndEnums() throws {
        let input = Data(
            """
            {
              "session_id": 987654321,
              "hook_event_name": true,
              "tool_name": 42,
              "permission_mode": false,
              "duration_ms": "15",
              "success": []
            }
            """.utf8
        )

        let event = try redacted(declaredEvent: "Stop", input: input)
        guard case let .object(payload) = event.payload else {
            return XCTFail("Expected an object payload")
        }

        XCTAssertEqual(payload["session_id"], .string("<redacted:invalid-type>"))
        XCTAssertEqual(payload["hook_event_name"], .string("<redacted:invalid-type>"))
        XCTAssertEqual(payload["tool_name"], .string("<redacted:invalid-type>"))
        XCTAssertEqual(payload["permission_mode"], .string("<redacted:invalid-type>"))
        XCTAssertEqual(payload["duration_ms"], .string("<redacted:invalid-type>"))
        XCTAssertEqual(payload["success"], .string("<redacted:invalid-type>"))
    }

    func testStatusLineKeepsOnlyAllowlistedAggregateTelemetry() throws {
        let input = Data(
            """
            {
              "session_id": "session-secret",
              "context_total_input_tokens": 85000,
              "context_used_percentage": 42.5,
              "five_hour_used_percentage": 17,
              "five_hour_resets_at": 2000000000,
              "seven_day_used_percentage": 31,
              "cwd": "/private/project",
              "branch": "private-branch",
              "last_assistant_message": "private reply"
            }
            """.utf8
        )

        let event = try redacted(declaredEvent: "StatusLine", input: input)
        guard case let .object(payload) = event.payload else {
            return XCTFail("Expected an object payload")
        }

        let sessionID = try XCTUnwrap((try XCTUnwrap(payload["session_id"])).stringValue)
        XCTAssertTrue(sessionID.hasPrefix("id_"))
        XCTAssertEqual(payload["context_total_input_tokens"], .number(85000))
        XCTAssertEqual(payload["context_used_percentage"], .number(42.5))
        XCTAssertEqual(payload["five_hour_used_percentage"], .number(17))
        // The reset time is not on the allowlist: nothing displays it, so it is dropped with
        // the unknown fields rather than carried across the socket unread.
        XCTAssertNil(payload["five_hour_resets_at"])
        XCTAssertNil(payload["branch"])
        XCTAssertEqual(payload["cwd"], .string("<redacted>"))
        XCTAssertEqual(payload["last_assistant_message"], .string("<redacted>"))
    }

    /// From raw bytes, the way the socket does it: decoded with `JSONDecoder` — which is what
    /// the ingress uses — and then redacted.
    ///
    /// There used to be a function in `AgentWatchCore` doing both steps, written for a capture
    /// executable that no longer exists. Keeping production code whose only caller is a test
    /// is how that code comes to rot, so the two steps are spelled out here instead.
    private func redacted(
        declaredEvent: String,
        input: Data
    ) throws -> (declaredEvent: String, payload: JSONValue) {
        try HookCaptureRedactor.redact(
            declaredEvent: declaredEvent,
            payload: try JSONDecoder().decode(JSONValue.self, from: input)
        )
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }
}
