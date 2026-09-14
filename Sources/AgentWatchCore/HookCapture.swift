import CoreFoundation
import CryptoKit
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    var isString: Bool {
        if case .string = self { true } else { false }
    }

    var isNumber: Bool {
        if case .number = self { true } else { false }
    }

    var isBool: Bool {
        if case .bool = self { true } else { false }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum HookCaptureError: Error, Equatable, Sendable {
    case expectedJSONObject
    case unsupportedDeclaredEvent
}

public enum HookCaptureRedactor {
    /// The most a hook payload may be. Enforced by the two places that actually read bytes —
    /// the sender, off standard input, and the listener, off the socket — rather than here,
    /// which never sees any.
    public static let maximumInputByteCount = 1_048_576

    /// The redaction, for a payload that has already been parsed.
    ///
    /// The app receives `JSONValue` off the socket and redacts it again — the sender is not
    /// trusted to have done it, because anything can connect to that socket. Re-encoding it
    /// to bytes just so `JSONSerialization` could parse it back cost a full round trip per
    /// event on the main thread and bought nothing.
    public static func redact(
        declaredEvent: String,
        payload: JSONValue
    ) throws -> (declaredEvent: String, payload: JSONValue) {
        guard supportedEventNames.contains(declaredEvent) else {
            throw HookCaptureError.unsupportedDeclaredEvent
        }
        guard case .object = payload else {
            throw HookCaptureError.expectedJSONObject
        }
        let projected = declaredEvent == "StatusLine" ? statusLineTelemetry(in: payload) : payload
        return (redactEventName(declaredEvent), redact(projected))
    }

    /// Claude's status line nests these aggregates. Project only the fields the protocol
    /// understands; the containers and all their other contents still go through redaction.
    /// Already-projected messages survive the app's second redaction unchanged.
    private static func statusLineTelemetry(in payload: JSONValue) -> JSONValue {
        guard case var .object(fields) = payload else {
            return payload
        }
        if case let .object(context)? = fields["context_window"] {
            fields["context_total_input_tokens"] = context["total_input_tokens"]
            fields["context_used_percentage"] = context["used_percentage"]
        }
        if case let .object(limits)? = fields["rate_limits"] {
            for window in ["five_hour", "seven_day"] {
                if case let .object(usage)? = limits[window] {
                    fields["\(window)_used_percentage"] = usage["used_percentage"]
                }
            }
        }
        return .object(fields)
    }

    private static func redact(_ value: JSONValue, key: String? = nil) -> JSONValue {
        if let key {
            let normalizedKey = canonicalKey(key)
            if isSensitiveKey(normalizedKey) {
                return .string("<redacted>")
            }
            if requiresStringValue.contains(normalizedKey), !value.isString {
                return .string("<redacted:invalid-type>")
            }
            if numberValueKeys.contains(normalizedKey), !value.isNumber {
                return .string("<redacted:invalid-type>")
            }
            if booleanValueKeys.contains(normalizedKey), !value.isBool {
                return .string("<redacted:invalid-type>")
            }
        }

        switch value {
        case let .object(fields):
            var redacted: [String: JSONValue] = [:]
            var redactedSensitiveFieldCount = 0
            var unknownFieldCount = 0
            for (childKey, childValue) in fields {
                let normalizedKey = canonicalKey(childKey)
                guard knownPayloadKeys.contains(normalizedKey) else {
                    if isSensitiveKey(normalizedKey) {
                        redactedSensitiveFieldCount += 1
                    } else {
                        unknownFieldCount += 1
                    }
                    continue
                }
                redacted[normalizedKey] = redact(childValue, key: normalizedKey)
            }
            if redactedSensitiveFieldCount > 0 {
                redacted["redacted_sensitive_field_count"] = .number(Double(redactedSensitiveFieldCount))
            }
            if unknownFieldCount > 0 {
                redacted["unknown_field_count"] = .number(Double(unknownFieldCount))
            }
            return .object(redacted)
        case let .array(items):
            return .array(items.map { redact($0, key: key) })
        case let .string(text):
            return redact(text, key: key)
        case .number, .bool, .null:
            return value
        }
    }

    private static func redact(_ value: String, key: String?) -> JSONValue {
        let normalizedKey = canonicalKey(key ?? "")

        if identifierKeys.contains(normalizedKey) {
            return .string("id_\(stableLabel(for: value))")
        }

        if supportedValues(for: normalizedKey).contains(value) {
            return .string(value)
        }

        return .string("<redacted>")
    }

    private static func redactEventName(_ value: String) -> String {
        supportedEventNames.contains(value) ? value : "<invalid-event-name>"
    }

    /// The label the app ends up knowing a raw identifier by.
    ///
    /// Hashed twice, and that is not an accident to be tidied away. The hook process redacts
    /// an identifier before it crosses the socket, and the app redacts whatever arrives all
    /// over again, because anything on this machine can connect to that socket and the sender
    /// is not trusted to have done its job. So `toolu_01…` reaches a snapshot as
    /// `hash(hash(toolu_01…))`.
    ///
    /// Anything that reads a raw identifier from somewhere other than the socket — the
    /// session transcript — has to arrive at exactly that string or it can correlate nothing.
    /// `HookCaptureRedactorTests` pins the two paths together, because if they drift apart the
    /// symptom is a reader that silently finds nothing rather than an error.
    public static func label(forRawIdentifier value: String) -> String {
        let acrossTheSocket = "id_\(stableLabel(for: value))"
        return "id_\(stableLabel(for: acrossTheSocket))"
    }

    private static func stableLabel(for value: String) -> String {
        let input = Data("agent-watch-hook-capture-v1:\(value)".utf8)
        let digest = SHA256.hash(data: input)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalKey(_ key: String) -> String {
        let camelCaseSeparated = key.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1_$2",
            options: .regularExpression
        )
        return
            camelCaseSeparated
            .replacingOccurrences(of: "[^a-zA-Z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .lowercased()
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        if telemetryNumberValueKeys.contains(key) {
            return false
        }
        if sensitiveKeys.contains(key) {
            return true
        }

        return key.split(separator: "_").contains { component in
            sensitiveKeyComponents.contains(String(component))
        }
    }

    private static let identifierKeys: Set<String> = [
        "session_id",
        // The session a fork was copied from, added by the sender from the process's own
        // arguments. A session identifier like the one above, and labelled the same way, so
        // the engine can match it against the row that identifier already has.
        "forked_from_session_id",
        "turn_id",
        "thread_id",
        "conversation_id",
        "prompt_id",
        "tool_use_id",
        "parent_tool_use_id",
        "subagent_id",
        "agent_id",
        "call_id",
    ]

    private static let sensitiveKeys: Set<String> = [
        "api_key",
        "arguments",
        "authorization",
        "command",
        "command_line",
        "content",
        "cwd",
        "description",
        "env",
        "environment",
        "file_path",
        "input",
        "instructions",
        "message",
        "path",
        "prompt",
        "query",
        "secret",
        "stderr",
        "stdin",
        "stdout",
        "text",
        "token",
        "tool_input",
        "tool_result",
        "tool_output",
        "tool_response",
        "transcript_path",
        "url",
        "user_prompt",
        "last_assistant_message",
        "background_tasks",
        "session_crons",
    ]

    private static let sensitiveKeyComponents: Set<String> = [
        "credential",
        "password",
        "secret",
        "token",
        "tokens",
    ]

    private static let knownPayloadKeys: Set<String> =
        identifierKeys
        .union(sensitiveKeys)
        .union(safeValueKeys)
        .union(telemetryNumberValueKeys)
        .union(["duration_ms", "stop_hook_active", "success"])

    private static let safeValueKeys: Set<String> = [
        "hook_event_name",
        "permission_mode",
        "source",
        "tool_name",
        "tool_use_type",
    ]

    private static let requiresStringValue = identifierKeys.union(safeValueKeys)
    private static let telemetryNumberValueKeys: Set<String> = [
        "context_total_input_tokens",
        "context_used_percentage",
        "five_hour_used_percentage",
        "seven_day_used_percentage",
    ]
    private static let numberValueKeys: Set<String> = Set(["duration_ms"]).union(telemetryNumberValueKeys)
    private static let booleanValueKeys: Set<String> = ["stop_hook_active", "success"]

    /// Every name `HookEventName` knows, and nothing else — one list instead of a second
    /// copy of it. A name accepted here that the normalizer cannot read would be refused a
    /// moment later; a name missing here is refused in the sending process, where hooks are
    /// fail-open, and that is silent.
    private static let supportedEventNames = HookEventName.allNames

    private static func supportedValues(for key: String) -> Set<String> {
        switch key {
        case "hook_event_name":
            supportedEventNames
        case "permission_mode":
            [
                "default", "dontAsk", "acceptEdits", "plan", "bypassPermissions", "read-only", "workspace-write",
                "danger-full-access",
            ]
        case "source":
            // `fork` is the documented start of a session copied with `--fork-session`, which
            // is how `/bg` and `/fork` continue a conversation in a new process.
            ["startup", "resume", "clear", "compact", "fork"]
        case "tool_name":
            [
                "AskUserQuestion", "Bash", "Edit", "ExitPlanMode", "Glob", "Grep", "NotebookEdit", "Read", "Skill",
                "Task", "TaskOutput", "TodoWrite", "WebFetch", "WebSearch", "Write",
            ]
        case "tool_use_type":
            ["function", "shell"]
        default:
            []
        }
    }
}
