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

    /// - Parameter directoryURL: where the file lives. Given only by tests, which must not
    ///   write into the running person's Application Support.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let directory =
            directoryURL
            ?? AgentWatchPaths.applicationSupportDirectory(fileManager: fileManager)
            .map { AgentWatchPaths.supportDirectory(inApplicationSupport: $0) }
        fileURL = directory?.appendingPathComponent("settings.json")
        values = Self.read(fileURL, fileManager: fileManager)
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
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func read(_ fileURL: URL?, fileManager: FileManager) -> [String: JSONValue] {
        guard
            let fileURL,
            let data = fileManager.contents(atPath: fileURL.path),
            let values = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return [:]
        }
        return values
    }
}
