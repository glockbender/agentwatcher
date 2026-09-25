import AgentWatchCore
import Darwin
import Foundation

/// Finds the agents running on this machine, whether or not any of them has ever spoken to
/// the app.
///
/// The counterpart of `AgentProcessLocator`, which answers the same kind of question about
/// one process the hook already has in hand. What counts as a session is each agent's rule
/// (`AgentProcessRules.liveSessions`); this asks every agent's rules and lends them the
/// listing of the machine. Only Claude's processes count sessions today — why Codex's do not
/// is written on `CodexProcessRules.liveSessions`.
public enum AgentProcessScanner {
    /// Every live agent session that can be found from processes, as much as a row can
    /// honestly say about one.
    public static func liveAgentProcesses() -> [DiscoveredAgentProcess] {
        AgentSource.allCases.flatMap { $0.processRules.liveSessions() }
    }

    static func allProcessIDs() -> [Int32] {
        let reported = proc_listallpids(nil, 0)
        guard reported > 0 else {
            return []
        }
        // Room to spare, because processes start between the two calls and the kernel fills
        // as much of the buffer as it is given without saying that it had more.
        var identifiers = [Int32](repeating: 0, count: Int(reported) * 2)
        // Both calls answer in processes, not bytes: `libproc` divides the kernel's byte count
        // by `sizeof(int)` before returning it. Read as bytes and divided once more, the
        // answer kept a quarter of the list — the newest quarter, since the kernel lists
        // newest first — so an agent running since yesterday was invisible and one a day old
        // flickered in and out at the boundary. `testProcessListingReachesLaunchd` holds this.
        let listed = proc_listallpids(&identifiers, Int32(identifiers.count * MemoryLayout<Int32>.size))
        guard listed > 0 else {
            return []
        }
        return Array(identifiers.prefix(Int(listed))).filter { $0 > 0 }
    }

    /// The name of the directory a process is working in, and never the path to it.
    ///
    /// The trim happens here rather than in a caller on purpose: this is the boundary the
    /// full path is not allowed to cross, the same discipline `ProcessSnapshot` states for
    /// executable paths. ADR-0001.
    static func workingDirectoryName(of processID: Int32) -> String? {
        guard let path = AgentProcessLocator.workingDirectoryPath(of: processID) else {
            return nil
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
