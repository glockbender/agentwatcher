import AgentWatchCore
import Foundation

/// The sessions the last launch knew about, so a restart does not start from an empty widget.
///
/// Kept in a file beside `agents-heard.json` and for the same reason: the `UserDefaults`
/// domain depends on how the app was launched — one name inside the bundle, another under
/// `swift run` — so a memory kept there would be lost on every switch between an installed
/// copy and a development build.
///
/// Everything written here has already passed through `SessionHistory.remembered`, so the
/// file holds no phase, no open call and no fault. That is what its name means: not what the
/// sessions are doing, but what would be restored if the app started now.
@MainActor
final class SessionHistoryStore {
    /// How long a written age stands before a newer one replaces it on disk.
    ///
    /// The age moves on nearly every event, several times a minute, and what it costs to be
    /// behind on it is a minute of apparent silence on a row nobody is looking at yet. Which
    /// sessions exist is a different matter and waits for nothing: see `update`.
    private static let resolution: TimeInterval = 60

    private let fileURL: URL?
    private var lastWriteAt: Date?
    private var writtenIdentities: Set<String>

    /// What the previous launch left behind, read once at startup.
    let remembered: [SessionSnapshot]

    /// Which session each running agent process belonged to, as the last launch heard it.
    ///
    /// Kept apart from the sessions because it outlives them: a row leaves this file when it
    /// is dismissed or swept, and its agent goes on running. The pairing is what lets the
    /// next launch recognise that process instead of putting up a nameless row for it.
    let rememberedAgentProcesses: [RememberedAgentProcess]

    /// - Parameter directoryURL: where the file lives. Given only by tests, which must not
    ///   write into the running user's Application Support.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        let directory =
            directoryURL
            ?? AgentWatchPaths.applicationSupportDirectory()
            .map { AgentWatchPaths.supportDirectory(inApplicationSupport: $0) }
        fileURL = directory?.appendingPathComponent("sessions-remembered.json")
        let document = Self.read(fileURL, fileManager: fileManager)
        remembered = document.sessions
        rememberedAgentProcesses = document.agentProcesses ?? []
        writtenIdentities = Self.identities(of: document.sessions, pairedWith: rememberedAgentProcesses)
    }

    /// Takes the current session list and keeps the file in step with it.
    ///
    /// A session appearing or leaving is written at once, because that is the answer the next
    /// launch reads: a restart a moment after a session ended must not bring it back, and one
    /// a moment after a session began must not lose it. Everything else — an age, a model, a
    /// context count — waits for the window, since being a minute behind on those costs a
    /// restored row a minute of apparent silence and nothing more.
    ///
    /// A session entering or leaving a wait counts as the first kind, not the second. It is
    /// the one part of a phase the file keeps at all, nothing else can bring it back, and
    /// waiting out the window would lose it in exactly the case a restart cares about — the
    /// app going away moments after the session started waiting for its person.
    /// - Parameter awaiting: waits the engine is still checking. They live in memory only,
    ///   so a write made while one is open has to carry it — see `SessionHistory.remembered`.
    /// - Parameter agentProcesses: which session each live agent process is. A pairing
    ///   appearing or being forgotten is the first kind of change too — it is about a process
    ///   that is running right now, and quitting a second later must not lose it.
    func update(
        _ sessions: [SessionSnapshot],
        awaiting: [String: SessionHistory.RememberedWait] = [:],
        agentProcesses: [RememberedAgentProcess] = [],
        at moment: Date
    ) {
        let records = SessionHistory.records(of: sessions, awaiting: awaiting)
        let identities = Self.identities(of: records, pairedWith: agentProcesses)
        if identities == writtenIdentities, let lastWriteAt,
            moment >= lastWriteAt, moment.timeIntervalSince(lastWriteAt) < Self.resolution
        {
            return
        }
        writtenIdentities = identities
        lastWriteAt = moment
        write(records, agentProcesses: agentProcesses)
    }

    /// What has to be on disk the moment it changes: which sessions there are, which of
    /// them is waiting for what, and which process is which session.
    private static func identities(
        of records: [SessionSnapshot],
        pairedWith agentProcesses: [RememberedAgentProcess]
    ) -> Set<String> {
        Set(records.map(identity))
            .union(agentProcesses.map { "process\u{1}" + $0.processLabel + "\u{1}" + $0.sessionLabel })
    }

    private static func identity(of record: SessionSnapshot) -> String {
        [record.id, record.phase.rawValue, record.awaitedActivityID ?? ""].joined(separator: "\u{1}")
    }

    private func write(_ records: [SessionSnapshot], agentProcesses: [RememberedAgentProcess]) {
        guard let fileURL else {
            return
        }
        // Fail open like every other write here: losing this costs an empty widget for one
        // restart, and it must never cost an event.
        guard
            let data = try? JSONEncoder().encode(
                Document(sessions: records, agentProcesses: agentProcesses)
            )
        else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The file's shape. Written by this app and read back by it, so the names are its own.
    ///
    /// A list added later is optional on the way in and always written on the way out. The
    /// sessions are the valuable part of this file and must not be lost over a field that
    /// did not exist when it was written — which is what happened once: every remembered row
    /// went, and the claim that they would all be found again was wrong twice over. The scan
    /// that finds agents is Claude-only, so a remembered Codex row is simply gone until its
    /// next hook; and a remembered wait is in no scan at all, since it is a fact about a
    /// person, not about a process.
    ///
    /// A property default does not do this: Swift's synthesized decoder still demands the
    /// key. It has to be an optional, read through `??`.
    private struct Document: Codable {
        var sessions: [SessionSnapshot]
        var agentProcesses: [RememberedAgentProcess]?
    }

    private static func read(_ fileURL: URL?, fileManager: FileManager) -> Document {
        guard
            let fileURL,
            let data = fileManager.contents(atPath: fileURL.path),
            let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            return Document(sessions: [], agentProcesses: nil)
        }
        return document
    }
}
