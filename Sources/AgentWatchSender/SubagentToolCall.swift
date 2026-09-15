import AgentWatchCore
import Foundation

/// Whether a hook was fired by a tool call running **inside a subagent** rather than by the
/// session itself.
///
/// Such a call is not the session's work and must never reach the app. Two measured facts
/// make that necessary rather than tidy:
///
/// 1. **A subagent's hooks arrive stamped with the parent session's identifier.** Measured,
///    not assumed: in a five-minute window in which the person's own session ran no command
///    at all, 48 shell calls appeared on its row, all under the parent's identifier.
/// 2. **Nothing can ever take them off again.** A tool call ends either by its own
///    `PostToolUse` — which arrived for none of those 48, not one — or by the transcript
///    reader finding its result. A subagent writes its results into a file of its own,
///    `…/<session>/subagents/agent-….jsonl`, which the app deliberately never reads: see
///    `TranscriptLocator.sessionIdentifier(inFileNamed:source:)`, which rejects that shape.
///
/// So the row only ever grew — a hundred shells "running" inside one long turn, cleared only
/// when the turn ended. What the row shows instead is the subagent itself, which is the
/// honest summary: that comes from `SubagentStart` / `SubagentStop`, which are not tool calls
/// and pass through untouched.
///
/// This was the only place the question could be asked at all. The hook payload carries the
/// transcript path, and a path never crosses the socket (ADR-0001), so the
/// app on the other side had nothing to tell one caller's tool call from another's.
///
/// **Both halves of that have since stopped being true, and this now answers `false` every
/// time.** Measured on 2.1.272: a subagent's hook carries the *parent's* `transcript_path`,
/// identical to the main thread's, and its own file arrives as `agent_transcript_path` on
/// `SubagentStop` alone — so the path test below recognises nobody. And point 2 above no
/// longer holds either: `PostToolUse` does arrive from a subagent now, carrying the same
/// `agent_id` as its `PreToolUse`, so such a call ends like any other.
///
/// Left in place rather than deleted, because deleting it is a decision about what a row
/// should count, not a tidy-up: `agent_id` now reaches the app on every hook, so the question
/// this type exists for can be asked there, where the answer can also be undone. See
/// `docs/architecture.md` §6 and `docs/agent-integration.md` §1в.
public enum SubagentToolCall {
    /// The events that say a tool call started or ended.
    ///
    /// `PermissionRequest` is deliberately not among them. A subagent whose tool needs
    /// approval is a session waiting for a person, and that is true of the session whether
    /// the call was made by the agent or by something it started.
    private static let toolCallEvents: Set<String> = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied",
    ]

    /// Fail-open, like everything else in the sender: a payload with no transcript path is a
    /// payload this cannot judge, and withholding an event on a guess would lose work the
    /// session really is doing.
    public static func fired(declaredEvent: String, payload: JSONValue) -> Bool {
        guard toolCallEvents.contains(declaredEvent) else {
            return false
        }
        guard
            case let .object(fields) = payload,
            case let .string(path)? = fields["transcript_path"]
        else {
            return false
        }
        return isSubagentTranscript(path)
    }

    /// The shape Claude gives a subagent's transcript: an `agent-…` file, in a `subagents`
    /// directory beside the session's own. Either half is enough — the two are checked
    /// separately so that renaming one of them degrades to "not a subagent" rather than to a
    /// wrong answer.
    static func isSubagentTranscript(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path)
        return file.lastPathComponent.hasPrefix("agent-")
            || file.deletingLastPathComponent().lastPathComponent == "subagents"
    }
}
