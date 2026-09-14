import AgentWatchCore
import Foundation

/// Everything the app remembers about how it should look and behave, in one file it owns.
///
/// `UserDefaults` was the wrong home for this, and the reason is measurable rather than
/// stylistic: the domain a process writes to depends on how it was launched. A bundled copy
/// uses its bundle identifier, a bare `swift build` executable uses its own file name, and a
/// bundle identifier that changes once leaves a third domain behind. Three of them had
/// collected on the development machine, each holding a different background, opacity and
/// widget frame — so a setting chosen in one build was invisible to the other, and the widget
/// moved and resized on every switch between them.
///
/// `SessionHistoryStore` already avoids this for the same reason and in the same folder. This
/// is the settings half of that decision.
///
/// The format is a flat JSON object of plain values, which is the other half of the point: a
/// lamp colour scheme is something a person wants to look at, correct by hand and copy to
/// another machine, and a binary property list deep inside the library is none of those.
final class PreferenceFile {
    private let fileURL: URL?
    private let fileManager: FileManager
    private var values: [String: JSONValue]
    /// A file that was there and could not be read, waiting to be kept aside before the first
    /// write replaces it. `nil` once it has been, or when there was nothing wrong.
    private var unreadableFile: URL?
    /// Where a file this app could not read was put, once it has been put there.
    ///
    /// Read by whoever says things out loud: a file kept aside in silence is a person's
    /// settings apparently reset for no reason.
    private(set) var unreadableFileKeptAt: URL?

    /// - Parameter directoryURL: where the file lives. Given only by tests, which must not
    ///   write into the running person's Application Support.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let directory =
            directoryURL
            ?? AgentWatchPaths.supportDirectory(fileManager: fileManager)
        fileURL = directory?.appendingPathComponent("settings.json")
        switch Self.read(fileURL, fileManager: fileManager) {
        case .none:
            values = [:]
        case let .values(stored):
            values = stored
        case .unreadable:
            values = [:]
            unreadableFile = fileURL
        }
    }

    func string(forKey key: String) -> String? {
        guard case let .string(value) = values[key] else {
            return nil
        }
        return value
    }

    func number(forKey key: String) -> Double? {
        guard case let .number(value) = values[key] else {
            return nil
        }
        return value
    }

    func flag(forKey key: String) -> Bool? {
        guard case let .bool(value) = values[key] else {
            return nil
        }
        return value
    }

    func set(_ value: String, forKey key: String) {
        write(.string(value), forKey: key)
    }

    func set(_ value: Double, forKey key: String) {
        write(.number(value), forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        write(.bool(value), forKey: key)
    }

    func removeValue(forKey key: String) {
        values.removeValue(forKey: key)
        flush()
    }

    /// Writes every value the file does not already have, in one go.
    ///
    /// Called at every launch, which is what makes the file complete: a fresh install gets
    /// the whole configuration written out rather than an empty file whose meaning is
    /// somewhere in the source, and a version that adds a setting fills in that one key
    /// without touching anything a person has chosen.
    func seed(_ defaults: [String: JSONValue]) {
        let missing = defaults.filter { values[$0.key] == nil }
        guard !missing.isEmpty else {
            return
        }
        values.merge(missing) { _, seeded in seeded }
        flush()
    }

    /// Puts these values back whatever they are now, in one write. For a reset.
    func replace(_ values: [String: JSONValue]) {
        self.values.merge(values) { _, replacement in replacement }
        flush()
    }

    private func write(_ value: JSONValue, forKey key: String) {
        values[key] = value
        flush()
    }

    /// The whole file on every write. It holds a couple of dozen short values and every write
    /// comes from a person operating a control, so the cost is invisible — and one write of a
    /// complete document cannot leave the file half updated.
    private func flush() {
        guard let fileURL else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Fail open, like every other write the app makes: losing a preference costs the
        // widget its appearance until it is set again, and it must never cost an event.
        guard let data = try? encoder.encode(values) else {
            return
        }
        // The folder is created by whichever collaborator gets there first, and on a first
        // launch that can be after the first setting is written.
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        keepAsideAFileThatCouldNotBeRead()
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Moves a file this app could not read out of the way of the one it is about to write.
    ///
    /// `README.md` says this file is a person's to edit, and an edit can be wrong: one
    /// trailing comma read as nothing at all, and the next write — the defaults, at launch —
    /// put its own contents where a lamp scheme used to be. Kept under a name that says what
    /// happened and when, the way `ToolingInstaller` keeps a file it is about to change.
    ///
    /// Fail-open like every other write here: if the file cannot be moved it is left alone
    /// and nothing is written over it, which loses a setting rather than a file.
    private func keepAsideAFileThatCouldNotBeRead() {
        guard let unreadableFile else {
            return
        }
        self.unreadableFile = nil
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let kept = unreadableFile.appendingPathExtension("unreadable-\(stamp)")
        guard (try? fileManager.moveItem(at: unreadableFile, to: kept)) != nil else {
            return
        }
        unreadableFileKeptAt = kept
    }

    /// What was found where the settings live.
    private enum StoredValues {
        /// No file — a first launch, and nothing to keep.
        case none
        case values([String: JSONValue])
        /// A file that is there and is not this file: kept, never overwritten in silence.
        case unreadable
    }

    private static func read(_ fileURL: URL?, fileManager: FileManager) -> StoredValues {
        guard let fileURL, let data = fileManager.contents(atPath: fileURL.path) else {
            return .none
        }
        guard let values = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return .unreadable
        }
        return .values(values)
    }
}
