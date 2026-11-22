import AgentWatchCore
import Foundation

/// What the widget has to say about memory and CPU: nothing while watching is off, and no
/// figures until a reading names the session.
///
/// Read by the widget at every rebuild and never stored in a row's model: a figure changes
/// every five seconds, and a model that changed with it would rebuild every row that often.
/// Rows restate their numbers in place instead (`HUDSessionRowView.refreshResources`).
struct WidgetResources {
    var isWatching = false
    var showsInCard = false
    var report: ResourceReport?

    /// The session's total, while watching is on and a reading has it. A thread in ChatGPT.app
    /// that a reading does not hold has no command running, which is nothing rather than unknown.
    func figure(for snapshot: SessionSnapshot) -> ResourceFigure? {
        guard isWatching, let report else {
            return nil
        }
        if let session = report.sessions[snapshot.id] {
            return session.figure
        }
        return Self.isAppThread(snapshot) ? ResourceFigure(footprint: 0, cpuLoad: nil) : nil
    }

    /// What the session's hover card says, or `nil` for nothing: watching or the card's switch
    /// is off, or the session has no process to measure.
    func card(for snapshot: SessionSnapshot) -> CardResources? {
        guard isWatching, showsInCard, Self.canMeasure(snapshot) else {
            return nil
        }
        guard let report else {
            return .notRead
        }
        if let session = report.sessions[snapshot.id] {
            return .measured(session, source: snapshot.source)
        }
        return Self.isAppThread(snapshot)
            ? .measured(SessionResources(sessionID: snapshot.id), source: snapshot.source) : .notRead
    }

    /// Whether a reading can hold this session at all: it is open, and either a process of its
    /// own is known or it is a thread whose commands a reading finds under the app's shared host.
    static func canMeasure(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.phase != .sessionClosed
            && (!ResourceAttribution.rootProcessIDs(of: snapshot).isEmpty || isAppThread(snapshot))
    }

    /// A Codex thread in ChatGPT.app: no process of its own — the agent is the app's shared
    /// `app-server` — so its hooks carry no process number, and a reading holds only the
    /// commands the thread started, found by the thread's id in their environment.
    static func isAppThread(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.source == .codex && snapshot.clientKind == .desktop
            && ResourceAttribution.rootProcessIDs(of: snapshot).isEmpty
    }
}
