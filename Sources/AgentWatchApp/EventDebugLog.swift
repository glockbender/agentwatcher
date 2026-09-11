import AgentWatchCore
import Foundation

@MainActor
final class EventDebugLog {
    /// How many entries the window keeps. Not private so the tests can state the rule in
    /// terms of the cap rather than repeat its value, which is a tuning choice.
    static let maximumEntryCount = 500
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
            let directoryURL = try directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
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
        linesOnDisk = stored.count
        entries = Array(stored.suffix(Self.maximumEntryCount))
    }

    private static func defaultDirectoryURL(fileManager: FileManager) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return AgentWatchPaths.supportDirectory(inApplicationSupport: applicationSupport)
    }

    /// How many lines the file holds, for a test that checks the log stays bounded.
    var storedLineCount: Int {
        linesOnDisk
    }

    func recentEntries() -> [String] {
        entries
    }

    func makeEntry(for message: String) -> String {
        "\(formatter.string(from: .now))  \(message)"
    }

    func append(_ entry: String) {
        guard let fileURL else {
            return
        }

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
        guard
            (try? handle.seekToEnd()) != nil,
            (try? handle.write(contentsOf: Data("\(entry)\n".utf8))) != nil
        else {
            return false
        }
        return true
    }

    private func rewrite(to fileURL: URL) {
        let contents = entries.joined(separator: "\n") + "\n"
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        linesOnDisk = entries.count
    }

    private static func storedEntries(at fileURL: URL?) -> [String] {
        guard
            let fileURL,
            let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return []
        }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
