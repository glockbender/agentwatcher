import AgentWatchCore
import Foundation

/// Claude Code's own records of the processes it runs, `~/.claude/sessions/<pid>.json`, read
/// for the one thing the path to the program cannot always say: that a live process is one of
/// its sessions.
///
/// The path fails in two measured ways (`docs/agent-processes.md`,
/// «Почему живой агент находится только у Claude»). An update deletes the version a long-running session was
/// started from, and the kernel then names no path at all.
/// And a background session gives the same file a second name inside `ClaudeCode.app`, which
/// the kernel then reports for every process running that version. The record is written by
/// the process itself and carries its start, so neither touches it.
///
/// Every folder Claude Code is run from keeps its own records — measured on Claude Code 2.1.294,
/// a Claude started with `CLAUDE_CONFIG_DIR` writes `sessions/<pid>.json` there and nothing
/// under `~/.claude` — so the registry reads one directory per folder.
public struct ClaudeSessionRegistry: Sendable {
    let directories: [URL]
    let startTime: @Sendable (Int32) -> Date?

    public init(
        directories: [URL] = ClaudeSessionRegistry.defaultDirectories(),
        startTime: @escaping @Sendable (Int32) -> Date? = AgentProcessLocator.startTime(of:)
    ) {
        self.directories = directories
        self.startTime = startTime
    }

    public init(directory: URL, startTime: @escaping @Sendable (Int32) -> Date? = AgentProcessLocator.startTime(of:)) {
        self.init(directories: [directory], startTime: startTime)
    }

    /// The records of every Claude folder the app was told about.
    public static func directories(in folders: AgentFolders) -> [URL] {
        folders.folders(for: .claude).map(directory(inFolder:))
    }

    /// The records of the folder this process's environment names: what a hook needs, since
    /// it runs inside the Claude whose record it looks for, with that Claude's variable.
    public static func defaultDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = AgentWatchPaths.homeDirectory()
    ) -> [URL] {
        [
            directory(
                inFolder: AgentFolders.reportingFolder(
                    source: .claude, transcriptPath: nil, environment: environment, home: home))
        ]
    }

    public static func directory(inFolder folder: URL) -> URL {
        folder.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Whether a record says this live process is one of Claude Code's.
    ///
    /// Only a record in its own process's file, naming that process, with a start the kernel
    /// agrees with. The start is required rather than taken on trust: a record can outlive its
    /// process, the number is then handed to a stranger, and this answer builds a row.
    func recordsLiveProcess(_ processID: Int32) -> Bool {
        record(ofLiveProcess: processID) != nil
    }

    /// The record of this live process, on the same terms as `recordsLiveProcess`: a record
    /// whose process has gone, or whose number now belongs to somebody else, is no record.
    public func record(ofLiveProcess processID: Int32) -> ClaudeSessionRecord? {
        for directory in directories {
            if let record = record(ofLiveProcess: processID, in: directory) {
                return record
            }
        }
        return nil
    }

    private func record(ofLiveProcess processID: Int32, in directory: URL) -> ClaudeSessionRecord? {
        let file = directory.appendingPathComponent("\(processID).json", isDirectory: false)
        guard
            let data = try? Data(contentsOf: file),
            let record = ClaudeSessionRecord(data: data),
            record.processID == processID,
            let recordedStart = record.startedAt,
            let kernelStart = startTime(processID),
            ClaudeSessionRecord.starts(recordedStart, match: kernelStart)
        else {
            return nil
        }
        return record
    }

    /// Every process a record speaks for — one listing per folder holding a dozen files,
    /// rather than a file looked up for every process on the machine.
    func liveProcessIDs() -> Set<Int32> {
        let names = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        }
        return Set(
            names.compactMap { name -> Int32? in
                guard name.hasSuffix(".json"), let processID = Int32(name.dropLast(".json".count)) else {
                    return nil
                }
                return recordsLiveProcess(processID) ? processID : nil
            })
    }
}
