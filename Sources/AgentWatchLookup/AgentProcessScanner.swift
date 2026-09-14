import AgentWatchCore
import Darwin
import Foundation

/// Finds the agents running on this machine, whether or not any of them has ever spoken to
/// the app.
///
/// The counterpart of `AgentProcessLocator`, which answers the same kind of question about
/// one process the hook already has in hand. It lives beside it so that "what is a Claude
/// process" and the `sysctl` calls behind it are written once.
///
/// **Claude only, and that is a measured limit rather than an omission.** One `claude`
/// process a person started is one session — the agent's own helpers are dropped in
/// `claudeProcessIDs` — and a Claude hook carries its process number — which is what
/// lets a discovered row hand itself over to the session when the first hook finally
/// arrives. Codex has neither property: its desktop application hosts many threads in one
/// process, and its hooks report no process number at all, so a discovered Codex row could
/// never be joined to the session it belongs to and would stand beside it forever. See
/// `docs/agent-integration.md`.
public enum AgentProcessScanner {
    /// How far up the tree a candidate is checked for an agent above it.
    ///
    /// The same depth `AgentProcessLocator` walks down from a hook, and for the same reason:
    /// a bound is what makes a cycle in the parent chain harmless.
    private static let maximumAncestorDepth = 16

    /// Every live agent process, as much as a row can honestly say about one.
    ///
    /// Measured on a machine with 156 processes: listing them costs 0.03 ms and reading
    /// every executable path 0.9 ms, which is why this can be done wherever the app already
    /// has a reason to look rather than on a timer of its own.
    public static func liveAgentProcesses() -> [DiscoveredAgentProcess] {
        let candidates = claudeProcessIDs()
        return
            candidates
            .filter { !hasAgentAncestor($0, among: candidates) }
            .compactMap { processID in
                // A process with no start time is one that has already gone: the same call
                // answers both questions, which is why the row is built from its result
                // rather than from the listing that named the process a moment ago.
                guard let startedAt = AgentProcessLocator.startTime(of: processID) else {
                    return nil
                }
                return DiscoveredAgentProcess(
                    source: .claude,
                    processID: processID,
                    startedAt: startedAt,
                    projectName: workingDirectoryName(of: processID),
                    clientKind: AgentProcessLocator.clientKind(ofAgentProcess: processID)
                )
            }
            .sorted { $0.processID < $1.processID }
    }

    /// Whether some Claude process was started with exactly these words after the program —
    /// `["attach", "3345bfdf"]` for a viewer of that job.
    ///
    /// Asked before a background session's press opens a viewer of its own, so that a second
    /// press finds the first viewer's tab instead of opening another. Helpers are not dropped
    /// here, because a viewer is one of the processes `claudeProcessIDs` drops.
    public static func isClaudeRunning(withWords words: [String]) -> Bool {
        allProcessIDs().contains { processID in
            guard let executablePath = AgentProcessLocator.executablePath(for: processID) else {
                return false
            }
            let snapshot = ProcessSnapshot(
                processID: processID,
                executableName: URL(fileURLWithPath: executablePath).lastPathComponent,
                executablePath: executablePath
            )
            guard AgentProcessLocator.isClaudeProcess(snapshot) else {
                return false
            }
            return AgentProcessLocator.commandWords(AgentProcessLocator.commandArguments(of: processID) ?? []) == words
        }
    }

    /// A helper an agent started for itself is not a second session.
    ///
    /// The other half of the same rule is `AgentProcessLocator.isHelperCommand`, which
    /// catches the helpers this one cannot: a helper whose parent has gone is reparented to
    /// `launchd` and has no agent above it any more.
    ///
    /// Only removes rows, never adds one, which is what makes it safe to apply before the
    /// case has been seen in the wild: an agent that turns out never to spawn another agent
    /// loses nothing to this check.
    private static func hasAgentAncestor(_ processID: Int32, among candidates: Set<Int32>) -> Bool {
        var current = processID
        for _ in 0..<maximumAncestorDepth {
            guard let parent = AgentProcessLocator.parentProcessID(of: current), parent > 1, parent != current
            else {
                return false
            }
            if candidates.contains(parent) {
                return true
            }
            current = parent
        }
        return false
    }

    private static func claudeProcessIDs() -> Set<Int32> {
        var found: Set<Int32> = []
        for processID in allProcessIDs() {
            guard let executablePath = AgentProcessLocator.executablePath(for: processID) else {
                continue
            }
            let snapshot = ProcessSnapshot(
                processID: processID,
                executableName: URL(fileURLWithPath: executablePath).lastPathComponent,
                executablePath: executablePath
            )
            guard AgentProcessLocator.isClaudeProcess(snapshot) else {
                continue
            }
            // Dropped here rather than from the finished list, and the order is the rule: a
            // helper left among the candidates would hide a real session running under it,
            // because the ancestry check below removes anything with an agent above it.
            guard !AgentProcessLocator.isHelperCommand(AgentProcessLocator.commandArguments(of: processID) ?? [])
            else {
                continue
            }
            found.insert(processID)
        }
        return found
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
    /// executable paths. `docs/architecture.md` §15.
    private static func workingDirectoryName(of processID: Int32) -> String? {
        guard let path = AgentProcessLocator.workingDirectoryPath(of: processID) else {
            return nil
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
