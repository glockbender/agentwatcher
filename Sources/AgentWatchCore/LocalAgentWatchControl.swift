import Foundation

/// A small, owner-only control message sent through Agent Watch's local socket.
/// It contains no agent content and is never forwarded from hooks.
public enum LocalAgentWatchControl {
    public static let revealExistingInstanceEvent = "agentwatch.reveal-existing-instance"

    public static func revealExistingInstanceRequest() -> HookIngressRequest {
        HookIngressRequest(
            source: .codex,
            declaredEvent: revealExistingInstanceEvent,
            payload: .object([:])
        )
    }

    public static func isRevealExistingInstance(_ request: HookIngressRequest) -> Bool {
        request.schemaVersion == HookIngressRequest.currentSchemaVersion
            && request.source == .codex
            && request.declaredEvent == revealExistingInstanceEvent
            && request.payload == .object([:])
            && request.agentProcessID == nil
    }
}
