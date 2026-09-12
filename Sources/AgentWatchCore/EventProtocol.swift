import Foundation

public enum EventKind: String, Codable, Sendable {
    case sessionStarted
    case sessionEnded
    case turnStarted
    case activityStarted
    case activityCompleted
    /// The call failed or was refused. Told apart from a completion because a completion can
    /// leave work behind and a refusal cannot.
    case activityFailed
    case userInputRequired
    case turnCompleted
    /// The turn ended in an API error rather than an answer (`StopFailure`).
    case turnFailed
    /// A person stopped the turn. Only Codex reports this; for Claude the same fact is
    /// readable only from the transcript, which is why reading it on silence exists.
    case turnInterrupted
    case statusUpdated
}

/// What the sender learned about a session from files only the hook process can read.
///
/// Grouped rather than passed as four more parameters: every branch of the normalizer has to
/// carry these through untouched, and a list of optional strings threaded through a dozen
/// call sites is where a field quietly stops being copied.
public struct SessionDescription: Codable, Equatable, Sendable {
    /// The agent's own name for the session.
    public let title: String?
    /// The project directory's own name — never the path that leads to it.
    public let projectName: String?
    public let gitBranch: String?
    /// Tokens the last turn carried into the model. No percentage: a transcript never says
    /// what its counts are a fraction of.
    public let contextInputTokens: Int?

    public init(
        title: String? = nil,
        projectName: String? = nil,
        gitBranch: String? = nil,
        contextInputTokens: Int? = nil
    ) {
        self.title = title
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.contextInputTokens = contextInputTokens
    }

    /// Far past any real context window, and far short of a number that would stretch a row
    /// past the width it was measured for. A count above this is not a count.
    public static let maximumContextInputTokens = 100_000_000

    public var isEmpty: Bool {
        title == nil && projectName == nil && gitBranch == nil && contextInputTokens == nil
    }
}

public struct EventEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let source: AgentSource
    public let sessionID: String
    public let description: SessionDescription?
    public let activityID: String?
    public let observedAt: Date
    public let kind: EventKind
    public let mode: SessionMode?
    public let activityKind: ActivityKind?
    /// Set only for a call that can still be running after its turn ends — a spawned
    /// subagent. See `SessionActivity.outlivesTurn`.
    public let activityOutlivesTurn: Bool
    /// Set for a call whose own completion does not end the work it started — a background
    /// shell. See `SessionActivity.outlivesItsCall`.
    public let activityOutlivesItsCall: Bool
    public let userInputRequestKind: UserInputRequestKind?
    public let agentProcessID: Int32?
    public let clientKind: SessionClientKind?
    public let contextTelemetry: SessionContextTelemetry?
    public let usageLimits: AgentUsageLimits?

    public init(
        schemaVersion: Int = EventEnvelope.currentSchemaVersion,
        source: AgentSource,
        sessionID: String,
        description: SessionDescription? = nil,
        activityID: String? = nil,
        observedAt: Date,
        kind: EventKind,
        mode: SessionMode? = nil,
        activityKind: ActivityKind? = nil,
        activityOutlivesTurn: Bool = false,
        activityOutlivesItsCall: Bool = false,
        userInputRequestKind: UserInputRequestKind? = nil,
        agentProcessID: Int32? = nil,
        clientKind: SessionClientKind? = nil,
        contextTelemetry: SessionContextTelemetry? = nil,
        usageLimits: AgentUsageLimits? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.sessionID = sessionID
        self.description = description
        self.activityID = activityID
        self.observedAt = observedAt
        self.kind = kind
        self.mode = mode
        self.activityKind = activityKind
        self.activityOutlivesTurn = activityOutlivesTurn
        self.activityOutlivesItsCall = activityOutlivesItsCall
        self.userInputRequestKind = userInputRequestKind
        self.agentProcessID = agentProcessID
        self.clientKind = clientKind
        self.contextTelemetry = contextTelemetry
        self.usageLimits = usageLimits
    }
}

public enum EventNormalizationError: Error, Equatable, Sendable {
    case unsupportedEvent(source: AgentSource, name: String)
    case missingSessionID
    case missingActivityID

    /// Why the event was refused, in a form safe to write into a local log.
    ///
    /// Built here rather than at the log because the interesting part — the event's declared
    /// name — arrives over a socket that any process running as this user can write to. Left
    /// raw it could put a newline into a file whose whole structure is one entry per line, or
    /// a bidirectional override that makes everything after it read backwards. The same
    /// sanitiser the description fields go through handles both.
    public var safeDescription: String {
        switch self {
        case let .unsupportedEvent(source, name):
            let named = HookIngressRequest.sanitizedText(
                name,
                limit: HookIngressRequest.maximumShortFieldLength
            )
            return
                "\(source.rawValue) sent \(named.map { "\"\($0)\"" } ?? "an event with no name"), which this app does not handle"
        case .missingSessionID:
            return "an event with no session it belongs to"
        case .missingActivityID:
            return "a tool event with no call it belongs to"
        }
    }
}

public enum EventIngestionError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public struct HookIngressRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let source: AgentSource
    public let declaredEvent: String
    public let payload: JSONValue
    public let agentProcessID: Int32?
    public let clientKind: SessionClientKind?
    /// What the sender read out of the session's own files.
    ///
    /// Free text written by a model or taken from a working directory. It is sanitised in
    /// `HookIngressProcessor.normalize`, not here: this type is decoded straight off the
    /// socket by a synthesized `Decodable`, which never runs the memberwise initialiser, so
    /// a cap applied here would guard only data the app produced itself and never what
    /// actually arrives.
    public let description: SessionDescription?
    /// Whether this tool call was asked to run in the background.
    ///
    /// Lifted out by the hook process rather than allowlisted inside `tool_input`: that
    /// object holds the command itself and is redacted whole, and weakening it for one
    /// boolean would open it for everything else. A flag is not content.
    ///
    /// It matters because the end of the call is not the end of the work: measured on real
    /// transcripts, a background `Bash` hands back a handle in about five seconds and the
    /// command runs on for as long as it likes.
    public let toolRunsInBackground: Bool?

    public static let maximumSessionTitleLength = 120
    /// A directory name and a branch name are both short by nature, and a long one is a
    /// sign of something other than a directory or a branch.
    public static let maximumShortFieldLength = 60

    public init(
        schemaVersion: Int = HookIngressRequest.currentSchemaVersion,
        source: AgentSource,
        declaredEvent: String,
        payload: JSONValue,
        agentProcessID: Int32? = nil,
        clientKind: SessionClientKind? = nil,
        description: SessionDescription? = nil,
        toolRunsInBackground: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.declaredEvent = declaredEvent
        self.payload = payload
        self.agentProcessID = agentProcessID
        self.clientKind = clientKind
        self.description = description
        self.toolRunsInBackground = toolRunsInBackground
    }

    /// Keeps hostile or malformed text from reaching the widget as layout or as an
    /// unbounded string. Token counts are clamped to something a session could plausibly
    /// carry rather than trusted.
    ///
    /// Public because the socket is no longer the only way in: the app reads the same values
    /// out of a transcript when it catches up after a restart, and a transcript is a file on
    /// disk that anything can write to. One rule for both, rather than one rule and a habit.
    public static func sanitized(_ raw: SessionDescription?) -> SessionDescription? {
        guard let raw else {
            return nil
        }
        let sanitized = SessionDescription(
            title: sanitizedText(raw.title, limit: maximumSessionTitleLength),
            // A directory's own name never contains a separator. `docs/architecture.md` §15
            // promises the app never receives a path, and this is where that promise is kept
            // rather than merely intended: the field skips `HookCaptureRedactor` entirely,
            // so a sender built from another tree could otherwise put a whole path in it.
            projectName: sanitizedText(raw.projectName, limit: maximumShortFieldLength)
                .flatMap { $0.contains("/") ? nil : $0 },
            gitBranch: sanitizedText(raw.gitBranch, limit: maximumShortFieldLength),
            contextInputTokens: raw.contextInputTokens.flatMap {
                $0 > 0 && $0 <= SessionDescription.maximumContextInputTokens ? $0 : nil
            }
        )
        return sanitized.isEmpty ? nil : sanitized
    }

    /// U+202A-202E and U+2066-2069: the embeddings, overrides and isolates.
    private static let bidirectionalControls: Set<Unicode.Scalar> = [
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]

    static func sanitizedText(_ raw: String?, limit: Int) -> String? {
        guard let raw else {
            return nil
        }
        // True control characters (general category Cc) are dropped, and so are the
        // bidirectional overrides and isolates. Not the whole `.format` category, and not
        // `CharacterSet.controlCharacters`: both cover the zero-width joiner, and removing
        // that would split a composed emoji into pieces. The overrides are separable from it
        // and are the ones that can make a label read backwards.
        let withoutControls = String(
            String.UnicodeScalarView(
                raw.unicodeScalars.map {
                    $0.properties.generalCategory == .control || Self.bidirectionalControls.contains($0)
                        ? " " : $0
                }
            )
        )
        let collapsed =
            withoutControls
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else {
            return nil
        }
        return String(collapsed.prefix(limit))
    }
}

public enum HookIngressError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public enum HookIngressProcessor {
    public static func normalize(
        _ request: HookIngressRequest,
        observedAt: Date
    ) throws -> EventEnvelope {
        guard request.schemaVersion == HookIngressRequest.currentSchemaVersion else {
            throw HookIngressError.unsupportedSchemaVersion(request.schemaVersion)
        }

        let captured = try HookCaptureRedactor.redact(
            declaredEvent: request.declaredEvent,
            payload: request.payload
        )

        return try HookEventNormalizer.normalize(
            source: request.source,
            declaredEvent: captured.declaredEvent,
            payload: captured.payload,
            observedAt: observedAt,
            agentProcessID: request.agentProcessID,
            clientKind: request.clientKind,
            description: HookIngressRequest.sanitized(request.description),
            toolRunsInBackground: request.toolRunsInBackground
        )
    }
}

public enum HookEventNormalizer {
    public static func normalize(
        source: AgentSource,
        declaredEvent: String,
        payload: JSONValue,
        observedAt: Date,
        agentProcessID: Int32? = nil,
        clientKind: SessionClientKind? = nil,
        description: SessionDescription? = nil,
        toolRunsInBackground: Bool? = nil
    ) throws -> EventEnvelope {
        guard case let .object(fields) = payload else {
            throw EventNormalizationError.missingSessionID
        }
        guard let sessionID = string("session_id", in: fields) else {
            throw EventNormalizationError.missingSessionID
        }

        let mode = sessionMode(from: string("permission_mode", in: fields))
        // Everything every branch has in common, filled once. Spelling out seven identical
        // arguments a dozen times over is where a field quietly stops being copied — the same
        // reason `SessionDescription` groups its four.
        func envelope(
            _ kind: EventKind,
            activityID: String? = nil,
            activityKind: ActivityKind? = nil,
            outlivesTurn: Bool = false,
            outlivesItsCall: Bool = false,
            userInputRequestKind: UserInputRequestKind? = nil,
            contextTelemetry: SessionContextTelemetry? = nil,
            usageLimits: AgentUsageLimits? = nil
        ) -> EventEnvelope {
            EventEnvelope(
                source: source,
                sessionID: sessionID,
                description: description,
                activityID: activityID,
                observedAt: observedAt,
                kind: kind,
                mode: mode,
                activityKind: activityKind,
                activityOutlivesTurn: outlivesTurn,
                activityOutlivesItsCall: outlivesItsCall,
                userInputRequestKind: userInputRequestKind,
                agentProcessID: agentProcessID,
                clientKind: clientKind,
                contextTelemetry: contextTelemetry,
                usageLimits: usageLimits
            )
        }

        switch declaredEvent {
        case "StatusLine":
            guard source == .claude else {
                throw EventNormalizationError.unsupportedEvent(source: source, name: declaredEvent)
            }
            return envelope(
                .statusUpdated,
                contextTelemetry: contextTelemetry(in: fields),
                usageLimits: usageLimits(source: source, fields: fields, observedAt: observedAt)
            )
        case "SessionStart":
            return envelope(.sessionStarted)
        case "SessionEnd":
            return envelope(.sessionEnded)
        case "UserPromptSubmit":
            return envelope(.turnStarted)
        case "Stop":
            return envelope(.turnCompleted)
        case "StopFailure":
            return envelope(.turnFailed)
        case "Interrupt":
            return envelope(.turnInterrupted)
        case "PermissionRequest":
            return envelope(.userInputRequired, userInputRequestKind: .approval)
        case "PreToolUse":
            guard let activityID = string("tool_use_id", in: fields) else {
                throw EventNormalizationError.missingActivityID
            }
            let toolName = string("tool_name", in: fields) ?? "Tool"
            if toolName == "AskUserQuestion" {
                return envelope(.userInputRequired, activityID: activityID, userInputRequestKind: .selection)
            }
            // A shell asked to run in the background is a different kind of work from a
            // shell the agent waits for, and it is the one case where the call's own
            // completion says nothing about whether the work is over.
            let runsInBackground = toolRunsInBackground == true && toolName == "Bash"
            return envelope(
                .activityStarted,
                activityID: activityID,
                activityKind: runsInBackground ? .backgroundTask : Self.activityKind(forToolNamed: toolName),
                outlivesTurn: runsInBackground,
                outlivesItsCall: runsInBackground
            )
        // A tool call ends in one of four ways, and only one of them is `PostToolUse`:
        // it succeeded. A failure reports `PostToolUseFailure`, a refusal reports
        // `PermissionDenied`, and an interruption reports nothing at all. All three that do
        // report are the same fact to a monitor — this call is over — so they normalize
        // alike; the interrupted case is what `Stop` and the next `UserPromptSubmit` have to
        // clean up.
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            guard let activityID = string("tool_use_id", in: fields) else {
                throw EventNormalizationError.missingActivityID
            }
            let succeeded = declaredEvent == "PostToolUse"
            return envelope(succeeded ? .activityCompleted : .activityFailed, activityID: activityID)
        // Compaction has no tool call and so no `tool_use_id`; one fixed identifier per
        // session is enough, because a session compacts one context at a time. The pair is
        // deliberately not marked as outliving the turn: if `PostCompact` never arrives —
        // compaction can fail — the end of the turn is what clears it.
        case "PreCompact":
            return envelope(.activityStarted, activityID: Self.compactionActivityID, activityKind: .compaction)
        case "PostCompact":
            return envelope(.activityCompleted, activityID: Self.compactionActivityID)
        case "SubagentStart":
            guard let activityID = identifier(in: fields, keys: ["agent_id", "subagent_id", "tool_use_id"]) else {
                throw EventNormalizationError.missingActivityID
            }
            return envelope(
                .activityStarted,
                activityID: activityID,
                activityKind: .subagent,
                outlivesTurn: true
            )
        case "SubagentStop":
            guard let activityID = identifier(in: fields, keys: ["agent_id", "subagent_id", "tool_use_id"]) else {
                throw EventNormalizationError.missingActivityID
            }
            return envelope(.activityCompleted, activityID: activityID)
        default:
            throw EventNormalizationError.unsupportedEvent(source: source, name: declaredEvent)
        }
    }

    /// A session compacts one context at a time, so its compaction needs no identifier of
    /// its own to be told apart from anything else in the same session.
    static let compactionActivityID = "compaction"

    /// What kind of work a tool call is, from its name alone.
    ///
    /// The subagent tool is deliberately absent: a call to it is an ordinary tool call, in
    /// flight for the two seconds it takes to hand back a handle. The subagent itself is
    /// described by `SubagentStart` and `SubagentStop`, which cover its whole life and land
    /// on the same session — measured, not assumed. Naming both a subagent counted one
    /// subagent as two for those two seconds.
    ///
    /// Only a name on `HookCaptureRedactor`'s tool allowlist ever reaches this function;
    /// anything else — every MCP tool, and `Agent` itself — arrives as `<redacted>` and lands
    /// in the default. Measured over six recent transcripts, that is 12% of all calls. So a
    /// case added here for a name outside that list would be dead code, and the test that
    /// covers this goes through the redactor rather than calling it directly.
    static func activityKind(forToolNamed toolName: String) -> ActivityKind {
        switch toolName {
        case "Bash": .shell
        default: .tool
        }
    }

    private static func string(_ key: String, in fields: [String: JSONValue]) -> String? {
        guard case let .string(value)? = fields[key] else {
            return nil
        }
        return value
    }

    private static func identifier(in fields: [String: JSONValue], keys: [String]) -> String? {
        keys.lazy.compactMap { string($0, in: fields) }.first
    }

    private static func sessionMode(from permissionMode: String?) -> SessionMode? {
        guard let permissionMode else {
            return nil
        }
        return permissionMode == "plan" ? .plan : .standard
    }

    private static func contextTelemetry(in fields: [String: JSONValue]) -> SessionContextTelemetry? {
        guard
            let totalInputTokens = nonNegativeInteger("context_total_input_tokens", in: fields),
            let usedPercentage = percentage("context_used_percentage", in: fields)
        else {
            return nil
        }
        return SessionContextTelemetry(
            totalInputTokens: totalInputTokens,
            usedPercentage: usedPercentage
        )
    }

    private static func usageLimits(
        source: AgentSource,
        fields: [String: JSONValue],
        observedAt: Date
    ) -> AgentUsageLimits? {
        let fiveHour = usageWindow(usedPercentageKey: "five_hour_used_percentage", in: fields)
        let sevenDay = usageWindow(usedPercentageKey: "seven_day_used_percentage", in: fields)
        guard fiveHour != nil || sevenDay != nil else {
            return nil
        }
        return AgentUsageLimits(
            source: source,
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            observedAt: observedAt
        )
    }

    private static func usageWindow(usedPercentageKey: String, in fields: [String: JSONValue]) -> UsageWindow? {
        percentage(usedPercentageKey, in: fields).map(UsageWindow.init(usedPercentage:))
    }

    private static func percentage(_ key: String, in fields: [String: JSONValue]) -> Double? {
        guard case let .number(value)? = fields[key], (0...100).contains(value) else {
            return nil
        }
        return value
    }

    private static func nonNegativeInteger(_ key: String, in fields: [String: JSONValue]) -> Int? {
        guard case let .number(value)? = fields[key], value >= 0,
            value <= Double(SessionDescription.maximumContextInputTokens)
        else {
            return nil
        }
        return Int(exactly: value)
    }
}
