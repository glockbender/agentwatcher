import AgentWatchCore
import Foundation

/// Each session's peak memory and CPU time, kept between launches so a closed session still has
/// figures to show (`ResourceHistory`).
///
/// In `session-resources.json` beside `sessions-remembered.json`, and for the same reason: the
/// `UserDefaults` domain changes with how the app was launched.
///
/// Written when a session that has a record ends — closed, or its row gone — and when the app
/// quits. Not on every reading: the figures of an open session move every five seconds, and
/// what a crash costs is the last stretch of an open session's figures, nothing of a closed one.
@MainActor
final class ResourceHistoryStore {
    private let fileURL: URL?
    private(set) var history: ResourceHistory
    /// Open sessions the history holds a record for, as of the last session list. One leaving
    /// this set is a session that ended, and its record goes to disk.
    private var watched: Set<String> = []
    private var open: Set<String> = []

    /// - Parameter directoryURL: where the file lives. Given only by tests, which must not
    ///   write into the running user's Application Support.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        let directory = directoryURL ?? AgentWatchPaths.supportDirectory()
        fileURL = directory?.appendingPathComponent("session-resources.json")
        history = ResourceHistory(records: Self.read(fileURL, fileManager: fileManager))
    }

    func add(_ report: ResourceReport) {
        history.add(report)
        watched.formUnion(open.intersection(report.sessions.keys))
    }

    func sessionsChanged(_ sessions: [SessionSnapshot]) {
        open = Set(sessions.filter { $0.phase != .sessionClosed }.map(\.id))
        let ended = watched.subtracting(open)
        guard !ended.isEmpty else {
            return
        }
        watched.subtract(ended)
        save()
    }

    /// Writes every record now. Called at quit, so open sessions keep what they have gathered.
    func save() {
        guard let fileURL else {
            return
        }
        // Fail open like every other write here: losing this costs a closed session its
        // figures, and it must never cost an event.
        guard let data = try? JSONEncoder().encode(Document(sessions: history.records)) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The file's shape. Written by this app and read back by it, so the names are its own.
    private struct Document: Codable {
        var sessions: [String: SessionResourceRecord]
    }

    private static func read(_ fileURL: URL?, fileManager: FileManager) -> [String: SessionResourceRecord] {
        guard
            let fileURL,
            let data = fileManager.contents(atPath: fileURL.path),
            let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            return [:]
        }
        return document.sessions
    }
}
