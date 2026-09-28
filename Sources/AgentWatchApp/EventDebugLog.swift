import AgentWatchCore
import Foundation

@MainActor
final class EventDebugLog {
    /// How many entries the window keeps. Not private so the tests can state the rule in
    /// terms of the cap rather than repeat its value, which is a tuning choice.
    static let maximumEntryCount = 500
    static let maximumEntryByteCount = 1024
    static let maximumFileByteCount = 1024 * 1024
    /// How far the file is allowed to run past the cap before it is rewritten. Trimming on
    /// every entry meant reading, joining and atomically rewriting the whole log for each
    /// event; letting it grow to twice the cap turns that into one rewrite per `maximumEntryCount`
    /// events and a single appended line for the rest.
    private static let maximumLinesOnDisk = maximumEntryCount * 2

    private let fileURL: URL?
    private let formatter: DateFormatter
    /// The window's backlog, kept here rather than re-read from disk on every append.
    private var entries: [String]
    private var linesOnDisk: Int

    /// - Parameter directoryURL: where the log lives. Given only by tests, which must not
    ///   write into the running user's Application Support.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        var fileURL: URL?
        do {
            guard let directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            fileURL = directoryURL.appendingPathComponent("event-debug.log")
        } catch {
            fileURL = nil
        }
        self.fileURL = fileURL

        let stored = Self.storedEntries(at: fileURL)
        linesOnDisk = stored.entries.count
        entries = Array(stored.entries.suffix(Self.maximumEntryCount))
        if stored.needsRewrite, let fileURL { rewrite(to: fileURL) }
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL? {
        AgentWatchPaths.supportDirectory(fileManager: fileManager)
    }

    /// How many lines the file holds, for a test that checks the log stays bounded.
    var storedLineCount: Int {
        linesOnDisk
    }

    func recentEntries() -> [String] {
        entries
    }

    func makeEntry(for message: String) -> String {
        Self.boundedEntry("\(formatter.string(from: .now))  \(Self.boundedEntry(message))")
    }

    func append(_ entry: String) {
        guard let fileURL else {
            return
        }

        let entry = Self.boundedEntry(entry)
        entries.append(entry)
        if entries.count > Self.maximumEntryCount {
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }

        guard linesOnDisk < Self.maximumLinesOnDisk, appendLine(entry, to: fileURL) else {
            rewrite(to: fileURL)
            return
        }
        linesOnDisk += 1
    }

    /// One line onto the end of the file. Answers whether it got there — a failure falls back
    /// to the rewrite, which also recreates a file somebody deleted underneath us.
    ///
    /// The handle is opened and closed each time rather than held. A handle kept open across
    /// a rewrite would go on appending to the replaced file, which no longer has a name and
    /// so cannot be found again by anything measuring the disk.
    private func appendLine(_ entry: String, to fileURL: URL) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            return false
        }
        defer { try? handle.close() }
        let data = Data("\(entry)\n".utf8)
        guard
            let size = try? handle.seekToEnd(),
            size <= UInt64(Self.maximumFileByteCount - data.count),
            (try? handle.write(contentsOf: data)) != nil
        else {
            return false
        }
        return true
    }

    private func rewrite(to fileURL: URL) {
        let contents = entries.joined(separator: "\n") + "\n"
        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            linesOnDisk = entries.count
        } catch {
            // Keep the old count so a failed compaction cannot reopen an append allowance.
        }
    }

    /// Limit bytes before decoding, so one large event cannot grow either the file or hidden UI.
    static func boundedEntry(_ entry: String) -> String {
        var bytes = Array(entry.utf8.prefix(maximumEntryByteCount + 1))
        let shortened = bytes.count > maximumEntryByteCount
        if shortened {
            bytes = Array(bytes.prefix(maximumEntryByteCount - "…".utf8.count))
            while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        }
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return text + (shortened ? "…" : "")
    }

    private static func storedEntries(at fileURL: URL?) -> (entries: [String], needsRewrite: Bool) {
        guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ([], false)
        }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > maximumFileByteCount ? size - UInt64(maximumFileByteCount) : 0
            try handle.seek(toOffset: offset)
            var data = try handle.read(upToCount: maximumFileByteCount) ?? Data()
            if offset > 0 {
                // The tail may start midway through a record or UTF-8 character.
                data = data.firstIndex(of: 10).map { Data(data.suffix(from: data.index(after: $0))) } ?? Data()
            }
            let raw = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            let entries = raw.map(boundedEntry)
            return (entries, offset > 0 || raw.count > maximumLinesOnDisk || raw != entries)
        } catch {
            return ([], false)
        }
    }
}
