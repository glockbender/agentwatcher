import AgentWatchCore
import AgentWatchIngress
import Foundation

/// The way hook events reach the app: a local socket, and the rules for what arrives on it.
///
/// Split out of `AppDelegate` for the same reason `SessionSupervisor` was — that class cannot
/// be built in a test, and these rules are the kind that fail quietly. A listener that cannot
/// start, an event nothing can be made of, and the one message that is not an event at all
/// are each one line of code and each worth a test.
@MainActor
final class HookIngressController {
    private let socketURL: () -> URL?
    private let ingest: (HookIngressRequest) -> EventEnvelope?
    private let reveal: () -> Void
    private let log: (String) -> Void
    private var ingress: UnixSocketIngress?

    /// - Parameters:
    ///   - socketURL: where to listen, or `nil` when this copy of the app has no address of
    ///     its own — which is a reason to carry on without a listener, not to stop.
    ///   - ingest: hands an accepted request to the sessions, and answers with the event it
    ///     became, or `nil` if it became none.
    ///   - reveal: bring the running copy of the app forward. Asked for by a second copy.
    init(
        socketURL: @escaping () -> URL?,
        ingest: @escaping (HookIngressRequest) -> EventEnvelope?,
        reveal: @escaping () -> Void,
        log: @escaping (String) -> Void
    ) {
        self.socketURL = socketURL
        self.ingest = ingest
        self.reveal = reveal
        self.log = log
    }

    /// Starts listening, or says why it could not.
    ///
    /// Never throws: monitoring is fail-open, so an app that cannot hear its hooks still runs
    /// and still shows whatever it can find by other means.
    func start() {
        guard let socketURL = socketURL() else {
            log("Local hook listener is unavailable")
            return
        }
        do {
            let ingress = UnixSocketIngress(socketPath: socketURL.path) { [weak self] result in
                // `DispatchQueue.main.async` and not `Task { @MainActor }`: the listener hands
                // events over in the order they arrived, and separately created tasks have no
                // order between them, so the hop was giving back the guarantee the listener
                // had just established. The main queue is first-in first-out.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handle(result)
                    }
                }
            }
            try ingress.start()
            self.ingress = ingress
            log("Listening for local hook events")
        } catch {
            log("Local hook listener is unavailable")
        }
    }

    func stop() {
        ingress?.stop()
        ingress = nil
    }

    /// What to do with one thing that arrived. Internal rather than private because this is
    /// where the rules are, and a test reaches them without a socket.
    func handle(_ result: Result<HookIngressRequest, UnixSocketIngressError>) {
        guard case let .success(request) = result else {
            log("Rejected malformed local hook event")
            return
        }

        if LocalAgentWatchControl.isRevealExistingInstance(request) {
            reveal()
            return
        }

        guard let event = ingest(request) else {
            log("Rejected unsupported local hook event")
            return
        }
        log(Self.describe(event))
    }

    /// One log line per accepted event, naming the session it belongs to.
    ///
    /// Without the identifier the log answers "what happened" but never "to which session",
    /// which is exactly the question when the list shows a row more than expected. Both
    /// identifiers here are the hashed labels that crossed the wire, not raw ones — the
    /// sender replaced them before sending, and this log is on disk.
    static func describe(_ event: EventEnvelope) -> String {
        var parts = [event.source.rawValue.capitalized, event.sessionID, event.kind.rawValue]
        if let activityKind = event.activityKind {
            parts[2] += " \(activityKind.rawValue)"
        }
        if let activityID = event.activityID {
            parts.append(activityID)
        }
        // Which subagent it came from, when it came from one. A session running several at
        // once produces one dialog and a stream of unrelated calls around it, and this is
        // what says which of them belong together.
        if let agentID = event.agentID {
            parts.append("from \(agentID)")
        }
        return parts.joined(separator: " · ")
    }
}
