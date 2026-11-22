import Foundation

/// Splits the sampled processes between the live rows and the shared hosts.
///
/// The rules, in the order they decide (`docs/proposals/resource-usage.md`):
///
/// 1. A process belongs to the nearest row root or shared host above it, itself included. The
///    tree wins over the environment: a `claude -p` started from a session inherits that
///    session's marker, and its commands are still its own.
/// 2. Under a row's root, a direct child that is a shell starts `commands`; any other child
///    starts a `helper` named after it. Everything under a child shares its part.
/// 3. Under a shared host, a direct child's subtree belongs to the thread the first marker in
///    it names. The marker is looked for below the child too: the child is usually a system
///    shell, and macOS does not show the environment of its own binaries. With no marker, a
///    shell is `unclaimedCommands` and anything else a `helper` grouped by name and folder.
/// 4. A subtree with no root or host above it is an orphan of the row its first marker names,
///    and unattributed when no live row answers to it.
///
/// Every process lands in exactly one bucket, so the totals add up to the processes handed in.
public enum ResourceAttribution {
    /// Names of the shells an agent runs its commands in: a shell child of an agent is a tool
    /// command, any other child a helper. `docs/agent-processes.md`, «Маркер сессии в окружении».
    static let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh"]

    /// The processes an open row's tree starts from: the agent's own and the viewer — the
    /// terminal a background session was sent from, which stays alive, shows the session and
    /// keeps MCP servers of its own (`SessionSnapshot.viewerProcessID`). The sampler walks down
    /// from these and attribution hands each process to the nearest one, so both read them here.
    public static func rootProcessIDs(of session: SessionSnapshot) -> [Int32] {
        guard session.phase != .sessionClosed else {
            return []
        }
        return [session.agentProcessID, session.viewerProcessID].compactMap { $0 }
    }

    public static func rootProcessIDs(of sessions: some Sequence<SessionSnapshot>) -> Set<Int32> {
        Set(sessions.flatMap { rootProcessIDs(of: $0) })
    }

    public static func report(
        table: ProcessTable,
        sessions: [SessionSnapshot],
        previous: ResourceReport?
    ) -> ResourceReport {
        let tree = ProcessTree(table: table, rows: RowDirectory(sessions))
        var sessionResources: [String: SessionResources] = [:]
        var hostResources: [Int32: HostResources] = [:]
        var totals = ResourceTotals()
        var basis = ResourceReport.RateBasis()

        for process in table.processes {
            let whole = usage(of: process, includingFinishedChildren: true)
            switch tree.owner(of: process.processID) {
            case let .session(id, part):
                var resources = sessionResources[id] ?? SessionResources(sessionID: id)
                if part == .agent {
                    // The agent's reaped children are its finished commands, not the agent.
                    let own = usage(of: process, includingFinishedChildren: false)
                    resources.parts[.agent, default: .zero].add(own)
                    totals.agents.add(own)
                    if process.finishedChildrenCPUTime > 0 {
                        let finished = ResourceUsage(cpuTime: process.finishedChildrenCPUTime)
                        resources.parts[.finishedCommands, default: .zero].add(finished)
                        totals.commands.add(finished)
                    }
                } else {
                    resources.parts[part, default: .zero].add(whole)
                    totals.add(whole, as: part)
                }
                resources.total.add(whole)
                basis.cpuTime[id, default: 0] += whole.cpuTime
                sessionResources[id] = resources
            case let .host(processID, part):
                guard let host = tree.hosts[processID] else {
                    continue
                }
                var resources = hostResources[processID] ?? HostResources(host: host)
                resources.parts[part, default: .zero].add(whole)
                resources.total.add(whole)
                totals.add(whole, as: part)
                basis.cpuTime[ProcessTree.bucket(host: processID), default: 0] += whole.cpuTime
                hostResources[processID] = resources
            case .unattributed:
                totals.unattributed.add(whole)
            }
        }

        basis.boundaries = tree.boundaries()
        var agentWatchLoad: Double?
        if let previous {
            agentWatchLoad = load(
                from: previous.agentWatch, to: table.agentWatch,
                over: table.sampledAt.timeIntervalSince(previous.sampledAt))
            let loads = cpuLoads(
                now: basis, at: table.sampledAt, liveProcesses: tree.processes, previous: previous)
            for id in sessionResources.keys {
                sessionResources[id]?.cpuLoad = loads[id]
            }
            for processID in hostResources.keys {
                hostResources[processID]?.cpuLoad = loads[ProcessTree.bucket(host: processID)]
            }
        }

        return ResourceReport(
            sampledAt: table.sampledAt,
            sessions: sessionResources,
            hosts: hostResources.values.sorted { $0.host.processID < $1.host.processID },
            totals: totals,
            agentWatch: table.agentWatch,
            agentWatchLoad: agentWatchLoad,
            machine: table.machine,
            rateBasis: basis
        )
    }

    private static func load(from before: ResourceUsage?, to now: ResourceUsage?, over interval: TimeInterval)
        -> Double?
    {
        guard let before, let now, interval > 0 else {
            return nil
        }
        return max(0, now.cpuTime - before.cpuTime) / interval
    }

    /// Cores used per bucket since the previous report.
    ///
    /// Only whole buckets get a load. A part's time moves between parts when a command ends —
    /// from `commands` into the agent's counter of finished children — so a load per part would
    /// show a finished command's whole life as one spike.
    ///
    /// Time crosses between buckets the same way. A subtree of one bucket that hangs under
    /// another — a thread's command under `app-server`, a nested row's root under a session's
    /// shell — lands in the other bucket's counter of finished children when it ends, after its
    /// own bucket has already shown it. So its last known time is taken off the reaping bucket
    /// once, in the report that no longer sees it. Taking off too much reads as idle, taking off
    /// too little as a spike, so it is the whole subtree's time rather than its top's: what is
    /// reaped is the top with every descendant it reaped first. A bucket whose time still went
    /// down — a process left without being reaped inside it — reads as idle rather than
    /// negative.
    static func cpuLoads(
        now: ResourceReport.RateBasis,
        at moment: Date,
        liveProcesses: [Int32: SampledProcess],
        previous: ResourceReport
    ) -> [String: Double] {
        let interval = moment.timeIntervalSince(previous.sampledAt)
        guard interval > 0 else {
            return [:]
        }
        var reaped: [String: TimeInterval] = [:]
        for (processID, boundary) in previous.rateBasis.boundaries where liveProcesses[processID] == nil {
            reaped[boundary.enclosingBucket, default: 0] += boundary.cpuTime
        }
        var loads: [String: Double] = [:]
        for (bucket, time) in now.cpuTime {
            guard let before = previous.rateBasis.cpuTime[bucket] else {
                continue
            }
            loads[bucket] = max(0, time - before - reaped[bucket, default: 0]) / interval
        }
        return loads
    }

    static func usage(of process: SampledProcess, includingFinishedChildren: Bool) -> ResourceUsage {
        ResourceUsage(
            footprint: process.footprint,
            resident: process.resident,
            cpuTime: process.cpuTime + (includingFinishedChildren ? process.finishedChildrenCPUTime : 0),
            processCount: 1
        )
    }
}

/// Which live row a process root or a marker answers to.
///
/// A marker resolves the way an event does in `SessionStateEngine`: to the row with its own
/// label first, then to the row it continues (`SessionSnapshot.continuedBy`). Closed rows answer
/// to nothing: what they leave running belongs to no live session.
struct RowDirectory {
    private(set) var roots: [Int32: String] = [:]
    private var labels: [SessionMarker: String] = [:]

    init(_ sessions: [SessionSnapshot]) {
        let live = sessions.filter { $0.phase != .sessionClosed }.sorted { $0.arrivalIndex < $1.arrivalIndex }
        for session in live {
            for processID in ResourceAttribution.rootProcessIDs(of: session) where roots[processID] == nil {
                roots[processID] = session.id
            }
            let own = SessionMarker(source: session.source, label: session.sessionLabel)
            if labels[own] == nil {
                labels[own] = session.id
            }
        }
        for session in live {
            for copy in session.continuedBy ?? [] {
                let marker = SessionMarker(source: session.source, label: copy)
                if labels[marker] == nil {
                    labels[marker] = session.id
                }
            }
        }
    }

    func row(for marker: SessionMarker) -> String? {
        labels[marker]
    }
}

/// The sampled processes as a tree, with the owner of each worked out once.
final class ProcessTree {
    enum Owner: Equatable {
        case session(String, ResourcePart)
        case host(Int32, HostPart)
        case unattributed
    }

    let processes: [Int32: SampledProcess]
    let hosts: [Int32: SharedAgentHost]
    private let rows: RowDirectory
    private var children: [Int32: [Int32]] = [:]
    private var owners: [Int32: Owner] = [:]

    init(table: ProcessTable, rows: RowDirectory) {
        processes = Dictionary(table.processes.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
        hosts = Dictionary(table.hosts.map { ($0.processID, $0) }, uniquingKeysWith: { first, _ in first })
        self.rows = rows
        for process in table.processes where processes[process.parentProcessID] != nil {
            children[process.parentProcessID, default: []].append(process.processID)
        }
    }

    static func bucket(host processID: Int32) -> String {
        "host:\(processID)"
    }

    func owner(of processID: Int32) -> Owner {
        if let known = owners[processID] {
            return known
        }
        let owner = resolveOwner(of: processID)
        owners[processID] = owner
        return owner
    }

    /// Every process whose bucket differs from its parent's, with the parent's bucket and the
    /// time of its whole subtree within its own bucket.
    func boundaries() -> [Int32: ResourceReport.Boundary] {
        var found: [Int32: ResourceReport.Boundary] = [:]
        for (processID, process) in processes {
            guard
                processes[process.parentProcessID] != nil,
                let enclosing = bucket(of: owner(of: process.parentProcessID)),
                let own = bucket(of: owner(of: processID)),
                enclosing != own
            else {
                continue
            }
            found[processID] = ResourceReport.Boundary(
                enclosingBucket: enclosing,
                cpuTime: subtreeTime(below: processID, bucket: own)
            )
        }
        return found
    }

    private func subtreeTime(below processID: Int32, bucket: String) -> TimeInterval {
        var time: TimeInterval = 0
        var queue = [processID]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            guard let process = processes[current], self.bucket(of: owner(of: current)) == bucket else {
                continue
            }
            time += process.cpuTime + process.finishedChildrenCPUTime
            queue.append(contentsOf: children[current] ?? [])
        }
        return time
    }

    private func bucket(of owner: Owner) -> String? {
        switch owner {
        case let .session(id, _): id
        case let .host(processID, _): Self.bucket(host: processID)
        case .unattributed: nil
        }
    }

    private func resolveOwner(of processID: Int32) -> Owner {
        guard let process = processes[processID] else {
            return .unattributed
        }
        if let row = rows.roots[processID] {
            return .session(row, .agent)
        }
        if hosts[processID] != nil {
            return .host(processID, .host)
        }
        guard let parent = processes[process.parentProcessID] else {
            // Nothing of ours above it: an orphan, if anything still names its session.
            guard let marker = firstMarker(under: processID, source: nil), let row = rows.row(for: marker) else {
                return .unattributed
            }
            return .session(row, .orphans)
        }
        if let row = rows.roots[parent.processID] {
            let isShell = ResourceAttribution.shellNames.contains(process.name)
            return .session(row, isShell ? .commands : .helper(process.name))
        }
        if let host = hosts[parent.processID] {
            return ownerOfHostChild(process, host: host)
        }
        return owner(of: parent.processID)
    }

    private func ownerOfHostChild(_ child: SampledProcess, host: SharedAgentHost) -> Owner {
        let marker = firstMarker(under: child.processID, source: host.source)
        if let marker, let row = rows.row(for: marker) {
            return .session(row, .commands)
        }
        if marker != nil || ResourceAttribution.shellNames.contains(child.name) {
            return .host(host.processID, .unclaimedCommands)
        }
        return .host(host.processID, .helper(name: child.name, workingDirectory: child.workingDirectory))
    }

    /// The marker of the first process in a subtree that has one, breadth first, the subtree's
    /// top included. Stops at the root of another row or host: what is under it is not this
    /// subtree's to name. Of one process's markers, one a live row answers to comes first.
    private func firstMarker(under processID: Int32, source: AgentSource?) -> SessionMarker? {
        var queue = [processID]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            if current != processID, rows.roots[current] != nil || hosts[current] != nil {
                continue
            }
            let markers = (processes[current]?.markers ?? []).filter { source == nil || $0.source == source }
            if let marker = markers.first(where: { rows.row(for: $0) != nil }) ?? markers.first {
                return marker
            }
            queue.append(contentsOf: children[current] ?? [])
        }
        return nil
    }
}

extension ResourceTotals {
    mutating func add(_ usage: ResourceUsage, as part: ResourcePart) {
        switch part {
        case .agent: agents.add(usage)
        case .helper: helpers.add(usage)
        case .commands, .finishedCommands: commands.add(usage)
        case .orphans: orphans.add(usage)
        }
    }

    mutating func add(_ usage: ResourceUsage, as part: HostPart) {
        switch part {
        case .host: agents.add(usage)
        case .helper: helpers.add(usage)
        case .unclaimedCommands: commands.add(usage)
        }
    }
}
