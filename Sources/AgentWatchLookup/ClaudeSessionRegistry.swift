import AgentWatchCore
import Foundation

/// Claude Code's own records of the processes it runs, `~/.claude/sessions/<pid>.json`, read
/// for the one thing the path to the program cannot always say: that a live process is one of
/// its sessions.
///
/// The path fails in two measured ways (`docs/agent-integration.md` §1б). An update deletes the
/// version a long-running session was started from, and the kernel then names no path at all.
/// And a background session gives the same file a second name inside `ClaudeCode.app`, which
/// the kernel then reports for every process running that version. The record is written by
/// the process itself and carries its start, so neither touches it.
///
/// The home is `~/.claude`, the same one the app reads everywhere; `CLAUDE_CONFIG_DIR` is not
/// honoured, the choice `TranscriptLocator` makes too.
public struct ClaudeSessionRegistry: Sendable {
    let directory: URL
    let startTime: @Sendable (Int32) -> Date?

    public init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        startTime: @escaping @Sendable (Int32) -> Date? = AgentProcessLocator.startTime(of:)
    ) {
        self.directory = directory
        self.startTime = startTime
    }

    /// Whether a record says this live process is one of Claude Code's.
    ///
    /// Only a record in its own process's file, naming that process, with a start the kernel
    /// agrees with. The start is required rather than taken on trust: a record can outlive its
    /// process, the number is then handed to a stranger, and this answer builds a row.
    func recordsLiveProcess(_ processID: Int32) -> Bool {
        let file = directory.appendingPathComponent("\(processID).json", isDirectory: false)
        guard
            let data = try? Data(contentsOf: file),
            let record = ClaudeSessionRecord(data: data),
            record.processID == processID,
            let recordedStart = record.startedAt,
            let kernelStart = startTime(processID)
        else {
            return false
        }
        return ClaudeSessionRecord.starts(recordedStart, match: kernelStart)
    }

    /// Every process a record speaks for — one listing of a folder holding a dozen files,
    /// rather than a file looked up for every process on the machine.
    func liveProcessIDs() -> Set<Int32> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(
            names.compactMap { name -> Int32? in
                guard name.hasSuffix(".json"), let processID = Int32(name.dropLast(".json".count)) else {
                    return nil
                }
                return recordsLiveProcess(processID) ? processID : nil
            })
    }
}
