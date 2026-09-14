import AgentWatchCore
import Foundation

/// When Agent Watch last had anything from each agent.
///
/// One question this answers and nothing else can: whether an installation has ever worked.
/// Hook records on disk say what a configuration asks for, not what an agent does with it —
/// Codex skips a hook it has not been told to trust, so the records sit there complete and
/// silent, and from the outside that is identical to an agent nobody used today.
///
/// Kept in a file rather than `UserDefaults` because the defaults domain depends on how the
/// app was launched: one name inside the bundle, another under `swift run`. A memory kept
/// there would reset on every switch between an installed copy and a development build, and
/// the app would report a broken installation that works.
@MainActor
final class AgentHeardStore {
    /// How long a recorded moment stands before a newer one replaces it on disk.
    ///
    /// The fact this exists for — heard at all, ever — is settled by the first write. The rest
    /// is the freshness of a date nothing reads yet, and events arrive several times a minute,
    /// so they are not worth a file rewrite each.
    private static let resolution: TimeInterval = 60

    private let fileURL: URL?
    private var heard: [AgentSource: Date]
    private var installed: Set<AgentSource>

    /// - Parameter directoryURL: where the file lives. Given only by tests, which must not
    ///   write into the running user's Application Support.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        let directory =
            directoryURL
            ?? AgentWatchPaths.supportDirectory()
        fileURL = directory?.appendingPathComponent("agents-heard.json")
        let document = Self.read(fileURL, fileManager: fileManager)
        heard = document.heard
        installed = document.installed
    }

    /// What is known about this agent's records ever having run.
    func delivery(for source: AgentSource) -> HookDelivery {
        if heard[source] != nil {
            return .arrived
        }
        // The narrow claim: silence is only evidence about records this app put there. Anything
        // else may have been working for months before it started keeping track.
        return installed.contains(source) ? .nothingSinceInstall : .unknown
    }

    /// Records that Agent Watch installed this agent's hooks itself, which is what makes a
    /// later silence worth reporting.
    func recordInstall(_ source: AgentSource) {
        guard !installed.contains(source) else {
            return
        }
        installed.insert(source)
        write()
    }

    /// Gives the claim up again, because records a person restores by hand are not ours to
    /// report on.
    func forgetInstall(_ source: AgentSource) {
        guard installed.contains(source) else {
            return
        }
        installed.remove(source)
        write()
    }

    /// Records that something arrived from this agent.
    ///
    /// Called for every event, including one the app could not understand: an event it refused
    /// still crossed the socket, which is exactly the thing being remembered here.
    func record(_ source: AgentSource, at moment: Date) {
        let previous = heard[source]
        heard[source] = moment
        guard let previous else {
            write()
            return
        }
        // A clock that went backwards writes too, because the stored date would otherwise
        // stay ahead of everything and never be replaced.
        if moment < previous || moment.timeIntervalSince(previous) >= Self.resolution {
            write()
        }
    }

    private func write() {
        guard let fileURL else {
            return
        }
        let contents = Document(
            heard: heard.reduce(into: [String: Double]()) { document, entry in
                document[entry.key.rawValue] = entry.value.timeIntervalSince1970
            },
            installed: installed.map(\.rawValue).sorted()
        )
        // Fail open like every other write here. Losing this costs one wrong sentence in a
        // menu, and it must never cost an event.
        guard let data = try? JSONEncoder().encode(contents) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The file's shape. Written by this app and read back by it, so the names are its own.
    private struct Document: Codable {
        var heard: [String: Double]
        var installed: [String]
    }

    private static func read(
        _ fileURL: URL?,
        fileManager: FileManager
    ) -> (heard: [AgentSource: Date], installed: Set<AgentSource>) {
        guard
            let fileURL,
            let data = fileManager.contents(atPath: fileURL.path),
            let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            return ([:], [])
        }
        let heard = document.heard.reduce(into: [AgentSource: Date]()) { heard, entry in
            guard let source = AgentSource(rawValue: entry.key) else {
                return
            }
            heard[source] = Date(timeIntervalSince1970: entry.value)
        }
        return (heard, Set(document.installed.compactMap(AgentSource.init(rawValue:))))
    }
}
