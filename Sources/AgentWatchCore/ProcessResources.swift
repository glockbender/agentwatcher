import Foundation

/// The session a process's environment names, already turned into the label a row answers to.
///
/// Both agents put their session's identifier in front of every command they start, and the
/// command keeps it after its parent is gone — the only thing that ties an orphan back to its
/// session. The raw identifier is labelled where it is read and never kept (ADR-0001).
/// `docs/agent-processes.md`, «Маркер сессии в окружении».
public struct SessionMarker: Hashable, Sendable {
    public let source: AgentSource
    /// `HookCaptureRedactor.label(forRawIdentifier:)` of the identifier the agent exported.
    public let label: String

    public init(source: AgentSource, label: String) {
        self.source = source
        self.label = label
    }
}

/// One process as the resource sampler saw it at one moment.
public struct SampledProcess: Equatable, Sendable {
    public let processID: Int32
    public let parentProcessID: Int32
    /// The executable's file name, never its path: what a helper is called (`plata-mcp`).
    public let name: String
    /// Bytes, as Activity Monitor's «Memory» column counts them: the process's own memory,
    /// compressed and swapped pages included.
    public let footprint: UInt64
    /// Bytes of that memory in RAM right now.
    public let resident: UInt64
    /// Seconds of processor time the process itself has used.
    public let cpuTime: TimeInterval
    /// Seconds used by the children the process waited for after they ended. The kernel adds
    /// a child's own time and its own counter here when the parent reaps it.
    public let finishedChildrenCPUTime: TimeInterval
    /// The sessions the environment names, in `AgentSource.allCases` order. Usually none or
    /// one; two when one agent was started from inside the other and inherited its marker.
    public let markers: [SessionMarker]
    /// Where the process works. Read only for the helpers of a shared host, as the key that
    /// groups them by project; never shown and never written to a log.
    public let workingDirectory: String?

    public init(
        processID: Int32,
        parentProcessID: Int32,
        name: String,
        footprint: UInt64 = 0,
        resident: UInt64 = 0,
        cpuTime: TimeInterval = 0,
        finishedChildrenCPUTime: TimeInterval = 0,
        markers: [SessionMarker] = [],
        workingDirectory: String? = nil
    ) {
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.name = name
        self.footprint = footprint
        self.resident = resident
        self.cpuTime = cpuTime
        self.finishedChildrenCPUTime = finishedChildrenCPUTime
        self.markers = markers
        self.workingDirectory = workingDirectory
    }
}

/// A process that holds many sessions and names none of them: Codex's `app-server` inside
/// ChatGPT.app runs every thread. Its rows have no process of their own, so the sampler finds
/// it rather than a row naming it.
public struct SharedAgentHost: Hashable, Sendable {
    public let processID: Int32
    public let source: AgentSource

    public init(processID: Int32, source: AgentSource) {
        self.processID = processID
        self.source = source
    }
}

/// How hard macOS is pressed for memory, as `kern.memorystatus_vm_pressure_level` says.
public enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical
}

/// The machine's memory, beside which the agents' share is read.
public struct MachineMemory: Equatable, Sendable {
    public let physical: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    public let pressure: MemoryPressure?

    public init(physical: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure?) {
        self.physical = physical
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }
}

/// Everything one pass of the sampler found: the processes that can belong to a session, the
/// shared hosts among them, and the two figures that belong to nobody's session.
public struct ProcessTable: Equatable, Sendable {
    public let sampledAt: Date
    public let processes: [SampledProcess]
    public let hosts: [SharedAgentHost]
    public let agentWatch: ResourceUsage?
    public let machine: MachineMemory?

    public init(
        sampledAt: Date,
        processes: [SampledProcess],
        hosts: [SharedAgentHost] = [],
        agentWatch: ResourceUsage? = nil,
        machine: MachineMemory? = nil
    ) {
        self.sampledAt = sampledAt
        self.processes = processes
        self.hosts = hosts
        self.agentWatch = agentWatch
        self.machine = machine
    }
}

/// Memory and processor time of a group of processes.
public struct ResourceUsage: Equatable, Sendable {
    public var footprint: UInt64
    public var resident: UInt64
    /// Seconds used so far, by the processes and by the children they waited for.
    public var cpuTime: TimeInterval
    public var processCount: Int

    public static let zero = ResourceUsage()

    public init(footprint: UInt64 = 0, resident: UInt64 = 0, cpuTime: TimeInterval = 0, processCount: Int = 0) {
        self.footprint = footprint
        self.resident = resident
        self.cpuTime = cpuTime
        self.processCount = processCount
    }

    public mutating func add(_ other: ResourceUsage) {
        footprint += other.footprint
        resident += other.resident
        cpuTime += other.cpuTime
        processCount += other.processCount
    }
}

/// What a part of a session is, from the agent's side of the tree.
public enum ResourcePart: Hashable, Sendable {
    /// The agent's own process. Claude's subagents run inside it.
    case agent
    /// A long-lived child that is not a shell, with everything under it — an MCP server.
    case helper(String)
    /// Tool commands still running: the shells the agent started and everything under them.
    case commands
    /// Processor time of the children the agent waited for after they ended. Memory is zero:
    /// nothing of them is left.
    case finishedCommands
    /// Processes whose parent is gone and whose environment still names the session.
    case orphans
}

/// One session's processes, split by part.
public struct SessionResources: Equatable, Sendable {
    public let sessionID: String
    public var parts: [ResourcePart: ResourceUsage]
    public var total: ResourceUsage
    /// Cores used over the interval since the previous report — 1 is one core fully busy —
    /// or `nil` on the first report that saw the session.
    public var cpuLoad: Double?

    public init(
        sessionID: String,
        parts: [ResourcePart: ResourceUsage] = [:],
        total: ResourceUsage = .zero,
        cpuLoad: Double? = nil
    ) {
        self.sessionID = sessionID
        self.parts = parts
        self.total = total
        self.cpuLoad = cpuLoad
    }
}

/// What a part of a shared host is.
public enum HostPart: Hashable, Sendable {
    /// The host process, with every child it waited for: its counter cannot be split by
    /// thread.
    case host
    /// A long-lived child that names no thread, grouped by name and working directory: an
    /// MCP server Codex started for the threads of one project.
    case helper(name: String, workingDirectory: String?)
    /// Commands whose thread has no live row, or that name no thread at all.
    case unclaimedCommands
}

public struct HostResources: Equatable, Sendable {
    public let host: SharedAgentHost
    public var parts: [HostPart: ResourceUsage]
    public var total: ResourceUsage
    public var cpuLoad: Double?

    public init(
        host: SharedAgentHost,
        parts: [HostPart: ResourceUsage] = [:],
        total: ResourceUsage = .zero,
        cpuLoad: Double? = nil
    ) {
        self.host = host
        self.parts = parts
        self.total = total
        self.cpuLoad = cpuLoad
    }
}

/// The agents' processes counted by kind, each process once.
public struct ResourceTotals: Equatable, Sendable {
    /// Agents' own processes and shared hosts.
    public var agents = ResourceUsage.zero
    /// MCP servers and other long-lived helpers, of sessions and of hosts.
    public var helpers = ResourceUsage.zero
    /// Running tool commands and the time of finished ones.
    public var commands = ResourceUsage.zero
    public var orphans = ResourceUsage.zero
    /// Processes the sampler handed in that no live row answers to.
    public var unattributed = ResourceUsage.zero

    public init() {}

    public var all: ResourceUsage {
        var sum = agents
        sum.add(helpers)
        sum.add(commands)
        sum.add(orphans)
        sum.add(unattributed)
        return sum
    }
}

/// What the agents cost the machine at one moment.
public struct ResourceReport: Equatable, Sendable {
    public let sampledAt: Date
    /// Keyed by `SessionSnapshot.id`.
    public let sessions: [String: SessionResources]
    public let hosts: [HostResources]
    public let totals: ResourceTotals
    public let agentWatch: ResourceUsage?
    /// Cores Agent Watch itself used since the previous report.
    public let agentWatchLoad: Double?
    public let machine: MachineMemory?
    /// What the next report needs to turn processor time into load. Not shown.
    let rateBasis: RateBasis

    struct RateBasis: Equatable, Sendable {
        /// Processor time of every bucket — a session id or `host:<pid>` — at `sampledAt`.
        var cpuTime: [String: TimeInterval] = [:]
        /// Tops of subtrees that hang under another bucket, with that bucket and the subtree's
        /// time: when such a subtree ends, its time lands in the other bucket's counter.
        var boundaries: [Int32: Boundary] = [:]
    }

    struct Boundary: Equatable, Sendable {
        let enclosingBucket: String
        let cpuTime: TimeInterval
    }
}
