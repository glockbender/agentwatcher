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

    /// The session's total, while watching is on and a reading has it.
    func figure(forSessionID id: String) -> ResourceFigure? {
        guard isWatching else {
            return nil
        }
        return report?.sessions[id]?.figure
    }

    /// What the session's hover card says, or `nil` for nothing: watching or the card's switch
    /// is off, or the session has no process to measure.
    func card(for snapshot: SessionSnapshot) -> CardResources? {
        guard isWatching, showsInCard, Self.canMeasure(snapshot) else {
            return nil
        }
        guard let session = report?.sessions[snapshot.id] else {
            return .notRead
        }
        return .measured(session, source: snapshot.source)
    }

    /// Whether a reading can hold this session at all: it is open and a process of its own,
    /// or the app that shows it, is known.
    static func canMeasure(_ snapshot: SessionSnapshot) -> Bool {
        !ResourceAttribution.rootProcessIDs(of: snapshot).isEmpty
    }
}
