import AgentWatchCore
import Foundation

/// Which of an agent's folders a fact about its hooks is about.
///
/// The default folder is a case of its own rather than a label like the others, because it is
/// what every fact meant before folders were told apart — a file written then still reads the
/// same — and because a sender that names no folder ran from it.
enum HeardFolder: Hashable {
    case `default`
    /// A folder a person listed, by `AgentFolders.label(of:)`.
    case listed(label: String)

    /// The key one agent's folder is kept under in the file: the agent's own name for the
    /// default folder, as it always was, and the name with the label for any other.
    func key(for source: AgentSource) -> String {
        switch self {
        case .default: source.rawValue
        case let .listed(label): "\(source.rawValue)@\(label)"
        }
    }

    /// The agent and folder a key in the file names, or `nil` for a key this app never wrote.
    static func parse(_ key: String) -> (AgentSource, HeardFolder)? {
        let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
        guard let source = AgentSource(rawValue: parts[0]) else {
            return nil
        }
        guard parts.count == 2 else {
            return (source, .default)
        }
        return (source, .listed(label: parts[1]))
    }
}

/// When Agent Watch last had anything from each agent's folders.
///
/// One question this answers and nothing else can: whether an installation has ever worked.
/// Hook records on disk say what a configuration asks for, not what an agent does with it —
/// Codex skips a hook it has not been told to trust, so the records sit there complete and
/// silent, and from the outside that is identical to an agent nobody used today. Kept per
/// folder because Codex asks for that trust in every folder separately: one folder reporting
/// says nothing about another.
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
    private var heard: [String: Date]
    private var installed: Set<String>

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

    /// What is known about the records in one of this agent's folders ever having run.
    func delivery(for source: AgentSource, folder: HeardFolder = .default) -> HookDelivery {
        let key = folder.key(for: source)
        if heard[key] != nil {
            return .arrived
        }
        // The narrow claim: silence is only evidence about records this app put there. Anything
        // else may have been working for months before it started keeping track.
        return installed.contains(key) ? .nothingSinceInstall : .unknown
    }

    /// Whether anything at all has arrived from this agent, from any of its folders.
    func hasHeard(from source: AgentSource) -> Bool {
        heard.keys.contains { HeardFolder.parse($0)?.0 == source }
    }

    /// Records that Agent Watch installed hooks into this folder itself, which is what makes a
    /// later silence worth reporting.
    func recordInstall(_ source: AgentSource, folder: HeardFolder = .default) {
        guard installed.insert(folder.key(for: source)).inserted else {
            return
        }
        write()
    }

    /// Gives the claim up again, because records a person restores by hand are not ours to
    /// report on.
    func forgetInstall(_ source: AgentSource, folder: HeardFolder = .default) {
        guard installed.remove(folder.key(for: source)) != nil else {
            return
        }
        write()
    }

    /// Records that something arrived from this agent's folder.
    ///
    /// Called for every event, including one the app could not understand: an event it refused
    /// still crossed the socket, which is exactly the thing being remembered here.
    func record(_ source: AgentSource, folder: HeardFolder = .default, at moment: Date) {
        let key = folder.key(for: source)
        let previous = heard[key]
        heard[key] = moment
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
            heard: heard.mapValues(\.timeIntervalSince1970),
            installed: installed.sorted()
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
    ) -> (heard: [String: Date], installed: Set<String>) {
        guard
            let fileURL,
            let data = fileManager.contents(atPath: fileURL.path),
            let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            return ([:], [])
        }
        let heard = document.heard.reduce(into: [String: Date]()) { heard, entry in
            guard HeardFolder.parse(entry.key) != nil else {
                return
            }
            heard[entry.key] = Date(timeIntervalSince1970: entry.value)
        }
        return (heard, Set(document.installed.filter { HeardFolder.parse($0) != nil }))
    }
}
