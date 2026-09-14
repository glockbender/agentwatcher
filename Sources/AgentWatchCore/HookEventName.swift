import Foundation

/// Every hook name this app understands, spelled as the agent spells it.
///
/// One list, because there were three, none derived from the others: what the app asks each
/// agent to send (`ToolingHooks`), what it will accept off the socket
/// (`HookCaptureRedactor`), and what it knows how to read (`HookEventNormalizer`). Nothing
/// tied them together, and the failure mode was silence — a hook registered but not accepted
/// is refused in the sending process, where hooks are fail-open by design, so nothing errors,
/// nothing is logged, and one kind of fact simply stops reaching the widget.
///
/// Now the normalizer switches over this type, so the compiler refuses a name it cannot read;
/// the two lists that do vary — which hooks each agent is asked for — are written in terms of
/// it, so a name that is not here is a build error rather than a quiet gap.
public enum HookEventName: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    /// A tool call that failed, and one that was refused. Neither reports `PostToolUse`, so
    /// without these two an activity had no way to end except by succeeding.
    case postToolUseFailure = "PostToolUseFailure"
    case permissionDenied = "PermissionDenied"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    /// A turn that ended in an API error instead of an answer.
    case stopFailure = "StopFailure"
    /// A turn a person stopped. Codex reports it; Claude does not.
    case interrupt = "Interrupt"
    case permissionRequest = "PermissionRequest"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case statusLine = "StatusLine"

    /// Every name, as the agents write them.
    public static let allNames = Set(allCases.map(\.rawValue))
}
