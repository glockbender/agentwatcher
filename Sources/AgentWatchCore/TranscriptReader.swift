import Foundation

/// Something that happened in a session and that no hook reports.
///
/// Every case here was measured on real transcripts before it was written down; the counts
/// are in `docs/architecture.md` §15.
public enum TranscriptFact: Equatable, Sendable {
    /// A tool call reported back — where the successful end of a call comes from, since
    /// `PostToolUse` is not registered with either agent.
    ///
    /// Closes an activity under the same rule a hook ending would, which means it does not
    /// close background work: a background shell is answered immediately with a handle while the
    /// command runs on, so treating this as the end would close the work the moment it
    /// started. `workEnded` is the case that closes those.
    case callReturned(activityID: String, at: Date)
    /// Work that outlived its own call has actually finished, or was killed.
    ///
    /// The only observation of that moment anywhere: the agent writes a task notification
    /// carrying the identifier of the call that started the work. Until this existed, the
    /// widget bounded such work by the start of the next turn, which is a guess.
    case workEnded(activityID: String, at: Date)
    /// A call the transcript is the only witness to has begun.
    ///
    /// The one fact here that opens an activity rather than closing one. Everything else the
    /// widget shows as running was announced by a hook first; an advisor call never is.
    case callStarted(activityID: String, kind: ActivityKind, at: Date)
    /// The turn was interrupted by a person.
    ///
    /// Measured with a control: an interrupted turn delivers no hook at all — not `Stop`, not
    /// `StopFailure` — while the same session delivered `Stop` twice for turns that ended
    /// normally. Without this the session goes on claiming it is working.
    case turnInterrupted(at: Date)

    /// When it happened, by the record's own timestamp wherever the record carried one.
    public var at: Date {
        switch self {
        case let .callReturned(_, at): at
        case let .workEnded(_, at): at
        case let .callStarted(_, _, at): at
        case let .turnInterrupted(at): at
        }
    }

    /// Whether this fact is the end of one particular call.
    ///
    /// A wait with no call named cannot be ended by any of these, which is why `nil` answers
    /// `false` rather than matching everything: such a wait is judged by whether the session
    /// did anything at all afterwards. See `SessionHistory.waitStillHolds`.
    public func ends(activityID: String?) -> Bool {
        guard let activityID else {
            return false
        }
        switch self {
        case let .callReturned(id, _), let .workEnded(id, _): return id == activityID
        case .callStarted, .turnInterrupted: return false
        }
    }
}

/// What one read of a transcript's tail produced.
public struct TranscriptIncrement: Equatable, Sendable {
    public let facts: [TranscriptFact]
    /// How far the caller may advance its saved offset: the end of the last complete line.
    ///
    /// The agent may be part-way through writing the last one, and a half-written line is not
    /// a fact — it is the same fact arriving later.
    public let consumedByteCount: Int
    /// When the newest record in this increment was written, over every line and not only the
    /// interesting ones.
    ///
    /// A session that is thinking, or writing a long answer, produces lines this reader has no
    /// facts to take from — and those lines are still proof it is alive. Without them a turn
    /// that calls no tool for two minutes is reported as silence nothing accounts for, which
    /// is a warning about a healthy session.
    ///
    /// `nil` when no line carried a timestamp this reader could parse. The caller decides what
    /// to put in its place, because only the caller knows when it read.
    public let newestRecordAt: Date?
    /// What the session said about itself in these lines. Never a lifecycle fact: nothing here
    /// moves a phase, and a session that names its model has not thereby done anything.
    public let signals: TranscriptSignals

    public init(
        facts: [TranscriptFact],
        consumedByteCount: Int,
        newestRecordAt: Date? = nil,
        signals: TranscriptSignals = TranscriptSignals()
    ) {
        self.facts = facts
        self.consumedByteCount = consumedByteCount
        self.newestRecordAt = newestRecordAt
        self.signals = signals
    }
}

public enum TranscriptReadError: Error, Equatable, Sendable {
    /// More has been appended than a live session can plausibly produce between two reads.
    ///
    /// Normal growth is 25–50 KB between reads. Anything at this scale means the offset is
    /// wrong — a resumed session, a file replaced under the same name — and parsing megabytes
    /// to find out would block the main thread for nothing. The caller re-syncs to the end of
    /// the file and reports it, because a re-sync silently skips whatever it jumped over.
    case incrementTooLarge(actualByteCount: Int)
}

/// Reads facts out of the tail of a session transcript.
///
/// Pure: bytes in, facts out. The file, the offset and the schedule belong to the caller, so
/// every rule here is testable without touching a disk.
///
/// Only three kinds of record are looked at out of the fourteen a transcript holds. Every
/// other line is skipped by its shape without its content being kept, which is what makes the
/// privacy note in §15 true: prompts and command output pass through a parse and are dropped.
public enum TranscriptReader {
    /// Four megabytes: eighty times the largest increment measured in ordinary use.
    public static let maximumIncrementByteCount = 4 * 1_048_576

    public static func read(
        increment: Data,
        source: AgentSource,
        observedAt: Date
    ) throws -> TranscriptIncrement {
        guard increment.count <= maximumIncrementByteCount else {
            throw TranscriptReadError.incrementTooLarge(actualByteCount: increment.count)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        var facts: [TranscriptFact] = []
        var consumed = 0
        var newestRecordAt: Date?
        var signals = TranscriptSignals()
        for line in completeLines(in: increment) {
            consumed = line.endIndexInIncrement
            guard
                let object = try? JSONSerialization.jsonObject(with: line.bytes) as? [String: Any]
            else {
                // A line that is not an object is not a failure. The format is undocumented
                // and has changed before; a reader that threw here would take the whole
                // session's monitoring down over one unfamiliar line.
                continue
            }
            let stamped = timestamp(in: object, formatter, plainFormatter)
            if let stamped {
                newestRecordAt = max(newestRecordAt ?? stamped, stamped)
            }
            let at = stamped ?? observedAt
            switch source {
            case .claude:
                facts += claudeFacts(in: object, at: at)
                signals = signals.merging(claudeSignals(in: object))
            case .codex:
                facts += codexFacts(in: object, at: at)
                signals = signals.merging(codexSignals(in: object))
            }
        }
        return TranscriptIncrement(
            facts: facts,
            consumedByteCount: consumed,
            newestRecordAt: newestRecordAt,
            signals: signals
        )
    }

    // MARK: - Claude

    private static func claudeFacts(in record: [String: Any], at: Date) -> [TranscriptFact] {
        guard let message = record["message"] as? [String: Any] else {
            return []
        }
        guard let parts = message["content"] as? [[String: Any]] else {
            return []
        }

        var facts: [TranscriptFact] = []
        for part in parts {
            switch part["type"] as? String {
            // Advisor and nothing else. A web search runs on the same side and is written the
            // same way; the widget has nothing to say about one, and naming it "advisor" would
            // be worse than staying silent.
            case "server_tool_use" where part["name"] as? String == "advisor":
                if let raw = part["id"] as? String {
                    facts.append(
                        .callStarted(
                            activityID: HookCaptureRedactor.label(forRawIdentifier: raw),
                            kind: .advisor,
                            at: at
                        ))
                }
            // An advisor call reports back in a record of its own, but it names the call the
            // same way and means the same thing, so it ends the same way.
            case "tool_result", "advisor_tool_result":
                if let raw = part["tool_use_id"] as? String {
                    facts.append(.callReturned(activityID: HookCaptureRedactor.label(forRawIdentifier: raw), at: at))
                }
            case "text":
                guard let text = part["text"] as? String else {
                    continue
                }
                // The text is read here and kept nowhere. What leaves this function is an
                // identifier or nothing at all.
                if let raw = taskNotificationToolUseID(in: text) {
                    facts.append(.workEnded(activityID: HookCaptureRedactor.label(forRawIdentifier: raw), at: at))
                } else if text.hasPrefix(interruptionMarker) {
                    facts.append(.turnInterrupted(at: at))
                }
            default:
                continue
            }
        }
        return facts
    }

    /// `[Request interrupted by user]` and `[Request interrupted by user for tool use]`, which
    /// mean the same thing to a session's phase: the turn is over and nobody said so.
    private static let interruptionMarker = "[Request interrupted by user"

    private static func taskNotificationToolUseID(in text: String) -> String? {
        guard text.contains("<task-notification>") else {
            return nil
        }
        return element("tool-use-id", in: text)
    }

    /// One element's text, without a regular expression: the surrounding document is a
    /// notification the agent wrote, not markup this reader has any business parsing.
    private static func element(_ name: String, in text: String) -> String? {
        guard
            let open = text.range(of: "<\(name)>"),
            let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else {
            return nil
        }
        let value = text[open.upperBound..<close.lowerBound]
        return value.isEmpty ? nil : String(value)
    }

    // MARK: - Codex

    /// Codex ends a call in two different places, and both are needed.
    ///
    /// A tool call and its output are separate records sharing a `call_id`, in a custom-tool
    /// and a function-call shape. But a shell command is not one of those: it is an `item` of
    /// type `CommandExecution` inside an `item_completed` record, identified by the item's own
    /// `id`. Measured against the app's own event log, `call_id` alone accounted for the tool
    /// calls and none of the 56 shell calls, which is how the second rule was found.
    private static func codexFacts(in record: [String: Any], at: Date) -> [TranscriptFact] {
        guard let payload = record["payload"] as? [String: Any] else {
            return []
        }
        switch (record["type"] as? String, payload["type"] as? String) {
        case ("response_item", "custom_tool_call_output"), ("response_item", "function_call_output"):
            guard let raw = payload["call_id"] as? String else {
                return []
            }
            return [.callReturned(activityID: HookCaptureRedactor.label(forRawIdentifier: raw), at: at)]
        case ("event_msg", "item_completed"):
            guard
                let item = payload["item"] as? [String: Any],
                let raw = item["id"] as? String
            else {
                return []
            }
            // Every completed item is reported, not just a command: an item the app never
            // opened as an activity closes nothing, and listing the item types here would be
            // a second place to keep in step with a format nobody documents.
            return [.callReturned(activityID: HookCaptureRedactor.label(forRawIdentifier: raw), at: at)]
        default:
            return []
        }
    }

    // MARK: - What a session says about itself

    /// The opening record of a file, read once when it is first found.
    ///
    /// Everything else here reads the tail, because the tail is where new facts are. These
    /// few values are stated once at the top and never repeated, so they are the one thing a
    /// tail can never deliver: the branch the session started on, and whether the thread is a
    /// person's or an agent's.
    ///
    /// Fail-open like every other parse. A head that cannot be read costs these values and
    /// nothing else — the lifecycle facts are why the reader exists, and they come from the
    /// other end of the file.
    public static func readOpening(_ head: Data, source: AgentSource) -> TranscriptSignals {
        guard source == .codex else {
            // Claude states its branch in the same records the hook sender already reads, and
            // reading it here as well would put two writers on one field.
            return TranscriptSignals()
        }
        for line in completeLines(in: head).prefix(openingRecordSearchLimit) {
            guard
                let object = try? JSONSerialization.jsonObject(with: line.bytes) as? [String: Any],
                object["type"] as? String == "session_meta",
                let payload = object["payload"] as? [String: Any]
            else {
                continue
            }
            return TranscriptSignals(
                gitBranch: text(payload["git"].flatMap { ($0 as? [String: Any])?["branch"] }),
                threadKind: threadKind(payload["thread_source"] as? String),
                threadNickname: text(payload["agent_nickname"])
            )
        }
        return TranscriptSignals()
    }

    /// How many bytes of the opening are worth reading, and how many lines of it are searched.
    ///
    /// A Codex opening record carries the whole system prompt — 17 KB in the files measured —
    /// so a small window would cut the record in half and find nothing. The line limit is
    /// what stops a file whose first record is missing from being scanned to its end.
    public static let openingByteCount = 256 * 1_024
    private static let openingRecordSearchLimit = 8

    private static func threadKind(_ raw: String?) -> SessionThreadKind? {
        switch raw {
        case "user": .user
        case "subagent": .subagent
        case "guardian_review": .review
        // An unfamiliar kind is not a kind. The vocabulary is undocumented and will grow, and
        // guessing one into the nearest case would state something nobody said.
        default: nil
        }
    }

    /// Claude names its model on every assistant record, which is the only signal here that
    /// both agents report. Its token counts are deliberately not read: the hook sender
    /// already reports them together with the percentage the hook stated, and a second
    /// reading would put one measurement under another's label.
    private static func claudeSignals(in record: [String: Any]) -> TranscriptSignals {
        guard let message = record["message"] as? [String: Any] else {
            return TranscriptSignals()
        }
        return TranscriptSignals(modelName: text(message["model"]))
    }

    /// Codex states the model on every turn and its token counts several times within one.
    private static func codexSignals(in record: [String: Any]) -> TranscriptSignals {
        guard let payload = record["payload"] as? [String: Any] else {
            return TranscriptSignals()
        }
        switch (record["type"] as? String, payload["type"] as? String) {
        case ("turn_context", _):
            return TranscriptSignals(
                modelName: text(payload["model"]),
                reasoningEffort: text(payload["effort"])
            )
        case ("event_msg", "token_count"):
            guard let info = payload["info"] as? [String: Any] else {
                return TranscriptSignals()
            }
            // `last_token_usage`, never `total_token_usage`. The total accumulates across
            // every turn of the session — measured at 3.6 million against a window of
            // 258 400 — so dividing it by the window yields 1398%, which is not a context
            // size but a sum of all the contexts there have ever been.
            let used = info["last_token_usage"] as? [String: Any]
            return TranscriptSignals(
                contextInputTokens: tokenCount(used?["input_tokens"]),
                contextWindowTokens: tokenCount(info["model_context_window"])
            )
        default:
            return TranscriptSignals()
        }
    }

    /// A number only if it is one a context can be described by. A transcript is a file on
    /// disk that anything can write to, and `Int(1e30)` traps.
    private static func tokenCount(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            case let count = number.doubleValue,
            count > 0,
            count <= Double(TranscriptSignals.maximumContextTokens)
        else {
            return nil
        }
        return Int(count)
    }

    /// A short, non-empty string. The cap is what keeps a model name a model name: this text
    /// goes straight into a row, and nothing on the writing end promises its length.
    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= maximumSignalTextLength else {
            return nil
        }
        return text
    }

    private static let maximumSignalTextLength = 64

    // MARK: - Lines and time

    private struct Line {
        let bytes: Data
        /// Offset just past this line's newline, so a caller can advance to it exactly.
        let endIndexInIncrement: Int
    }

    /// Complete lines only. A trailing fragment with no newline is left for the next read.
    ///
    /// An empty line is kept rather than skipped, because it still moves the offset: dropping
    /// it would leave the caller re-reading the same bytes on every tick. It parses as
    /// nothing and is discarded a step later, which is the same treatment every uninteresting
    /// line gets.
    private static func completeLines(in increment: Data) -> [Line] {
        var lines: [Line] = []
        var start = increment.startIndex
        for index in increment.indices where increment[index] == UInt8(ascii: "\n") {
            let end = increment.index(after: index)
            lines.append(
                Line(
                    bytes: Data(increment[start..<index]),
                    endIndexInIncrement: increment.distance(from: increment.startIndex, to: end)
                )
            )
            start = end
        }
        return lines
    }

    private static func timestamp(
        in record: [String: Any],
        _ withFraction: ISO8601DateFormatter,
        _ withoutFraction: ISO8601DateFormatter
    ) -> Date? {
        guard let text = record["timestamp"] as? String else {
            return nil
        }
        return withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }
}
