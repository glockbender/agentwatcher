import AgentWatchCore
import Darwin
import Foundation

/// Reads, from the kernel, the processes that can belong to an agent's session and what each
/// of them costs.
///
/// Three kinds of tree are read: below the processes of the rows the app names, below every
/// shared host (Codex's `app-server`), and below every orphan whose environment names a
/// session. Which session each process belongs to is decided elsewhere, by
/// `ResourceAttribution`: this only asks the machine.
///
/// A value, so a pass can run off the main thread with the sampler handed over and back. What
/// it remembers between passes is what does not change while a process lives — its name, its
/// markers, whether it is a host — keyed by process number and start time, so a new process
/// under a reused number is read afresh rather than inheriting another's markers.
public struct ProcessResourceSampler: Sendable {
    private let kernel: ProcessKernel
    private let agents: [AgentEntry]
    private let markerVariables: Set<String>
    private var known: [ProcessIdentity: ProcessFacts] = [:]

    public init() {
        self.init(kernel: .live)
    }

    init(kernel: ProcessKernel, agents: [AgentSource] = AgentSource.allCases) {
        self.kernel = kernel
        self.agents = agents.map { AgentEntry(source: $0, rules: $0.processRules) }
        markerVariables = Set(self.agents.map(\.rules.sessionMarkerVariable))
    }

    /// One pass over the machine.
    ///
    /// - Parameter rootProcessIDs: the agent processes of the rows that are still open.
    public mutating func sample(rootProcessIDs: Set<Int32>, at moment: Date) -> ProcessTable {
        var pass = Pass(kernel: kernel, agents: agents, markerVariables: markerVariables, known: known)
        let table = pass.run(rootProcessIDs: rootProcessIDs, at: moment)
        known = pass.seen
        return table
    }
}

struct AgentEntry: Sendable {
    let source: AgentSource
    let rules: any AgentProcessRules
}

struct ProcessIdentity: Hashable, Sendable {
    let processID: Int32
    let startedAt: UInt64
}

/// What does not change while a process lives, read the first time it is needed.
struct ProcessFacts: Sendable {
    var pathChecked = false
    var executablePath: String?
    var hostChecked = false
    var host: AgentSource?
    var markers: [SessionMarker]?
    var workingDirectoryChecked = false
    var workingDirectory: String?
}

/// One pass: everything it reads about a process is kept in `seen`, which becomes what the
/// sampler remembers.
private struct Pass {
    enum Reason {
        /// Under a row's process: the tree decides, no environment is read.
        case tree
        /// Under a shared host or an orphan: the markers decide.
        case markers
    }

    let kernel: ProcessKernel
    let agents: [AgentEntry]
    let markerVariables: Set<String>
    let known: [ProcessIdentity: ProcessFacts]
    var seen: [ProcessIdentity: ProcessFacts] = [:]
    var basics: [Int32: ProcessBasics] = [:]
    var children: [Int32: [Int32]] = [:]
    var included: [Int32: Reason] = [:]

    init(
        kernel: ProcessKernel, agents: [AgentEntry], markerVariables: Set<String>,
        known: [ProcessIdentity: ProcessFacts]
    ) {
        self.kernel = kernel
        self.agents = agents
        self.markerVariables = markerVariables
        self.known = known
    }

    mutating func run(rootProcessIDs: Set<Int32>, at moment: Date) -> ProcessTable {
        for processID in kernel.listProcessIDs() {
            if let found = kernel.basics(processID) {
                basics[processID] = found
            }
        }
        for (processID, found) in basics where found.parentProcessID != processID {
            children[found.parentProcessID, default: []].append(processID)
        }

        let ownProcesses = basics.filter { $0.value.userID == kernel.userID && $0.key != kernel.ownProcessID }
        var hosts: [SharedAgentHost] = []
        for processID in ownProcesses.keys.sorted() {
            if let source = host(processID) {
                hosts.append(SharedAgentHost(processID: processID, source: source))
            }
        }
        for host in hosts {
            include(below: host.processID, reason: .markers)
        }
        for processID in rootProcessIDs.sorted() where basics[processID] != nil {
            include(below: processID, reason: .tree)
        }
        for (processID, found) in ownProcesses.sorted(by: { $0.key < $1.key }) where included[processID] == nil {
            let parentIsGone = found.parentProcessID == 1 || basics[found.parentProcessID] == nil
            if processID != 1, parentIsGone, !isApplication(processID), !markers(processID).isEmpty {
                include(below: processID, reason: .markers)
            }
        }

        let hostIDs = Set(hosts.map(\.processID))
        var processes: [SampledProcess] = []
        for processID in included.keys.sorted() {
            guard let found = basics[processID], let usage = kernel.usage(processID) else {
                continue
            }
            let readsMarkers = included[processID] == .markers
            let isHostChild = hostIDs.contains(found.parentProcessID)
            processes.append(
                SampledProcess(
                    processID: processID,
                    parentProcessID: found.parentProcessID,
                    name: name(processID),
                    footprint: usage.footprint,
                    resident: usage.resident,
                    cpuTime: usage.cpuTime,
                    finishedChildrenCPUTime: usage.finishedChildrenCPUTime,
                    markers: readsMarkers ? markers(processID) : [],
                    workingDirectory: isHostChild ? workingDirectory(processID) : nil
                ))
        }

        let own = kernel.usage(kernel.ownProcessID).map {
            ResourceUsage(
                footprint: $0.footprint,
                resident: $0.resident,
                cpuTime: $0.cpuTime + $0.finishedChildrenCPUTime,
                processCount: 1
            )
        }
        return ProcessTable(
            sampledAt: moment,
            processes: processes,
            hosts: hosts,
            agentWatch: own,
            machine: kernel.machineMemory()
        )
    }

    /// A process and everything under it. A process already included keeps its first reason,
    /// so a host or a root inside another tree is read the way its own tree reads it.
    private mutating func include(below processID: Int32, reason: Reason) {
        var queue = [processID]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            guard included[current] == nil else {
                continue
            }
            included[current] = reason
            queue.append(contentsOf: children[current] ?? [])
        }
    }

    private mutating func host(_ processID: Int32) -> AgentSource? {
        var current = facts(processID)
        if !current.hostChecked {
            let commandName = basics[processID]?.commandName ?? ""
            current.host =
                agents.first { agent in
                    agent.rules.isSharedHost(
                        executableName: commandName,
                        executablePath: { kernel.executablePath(processID) },
                        arguments: { kernel.arguments(processID) }
                    )
                }?
                .source
            current.hostChecked = true
            store(current, for: processID)
        }
        return current.host
    }

    private mutating func markers(_ processID: Int32) -> [SessionMarker] {
        var current = facts(processID)
        if let markers = current.markers {
            return markers
        }
        let values = kernel.environmentValues(processID, markerVariables)
        let markers = agents.compactMap { agent -> SessionMarker? in
            guard let raw = values[agent.rules.sessionMarkerVariable], !raw.isEmpty else {
                return nil
            }
            return SessionMarker(source: agent.source, label: HookCaptureRedactor.label(forRawIdentifier: raw))
        }
        current.markers = markers
        store(current, for: processID)
        return markers
    }

    private mutating func name(_ processID: Int32) -> String {
        let fromPath = executablePath(processID).map { URL(fileURLWithPath: $0).lastPathComponent }
        return fromPath.flatMap { $0.isEmpty ? nil : $0 } ?? basics[processID]?.commandName ?? "?"
    }

    /// An installed application, which an orphan's marker does not make a session's.
    ///
    /// An application a thread's command started carries the thread's marker, as a daemon the
    /// thread left running does (`docs/agent-processes.md`, «Маркер сессии в окружении»).
    /// The daemon is leftover work; the application is not, and OrbStack's virtual machine would
    /// have been charged to one thread's row. Only installed ones are left out: a browser a test
    /// left behind lives in a bundle under a cache folder, and it is exactly the leftover this is
    /// for.
    private mutating func isApplication(_ processID: Int32) -> Bool {
        guard let path = executablePath(processID) else {
            return false
        }
        return kernel.applicationFolders.contains { path.hasPrefix($0) }
    }

    private mutating func executablePath(_ processID: Int32) -> String? {
        var current = facts(processID)
        if !current.pathChecked {
            current.executablePath = kernel.executablePath(processID)
            current.pathChecked = true
            store(current, for: processID)
        }
        return current.executablePath
    }

    private mutating func workingDirectory(_ processID: Int32) -> String? {
        var current = facts(processID)
        if !current.workingDirectoryChecked {
            current.workingDirectory = kernel.workingDirectory(processID)
            current.workingDirectoryChecked = true
            store(current, for: processID)
        }
        return current.workingDirectory
    }

    private mutating func facts(_ processID: Int32) -> ProcessFacts {
        guard let identity = identity(processID) else {
            return ProcessFacts()
        }
        if let current = seen[identity] {
            return current
        }
        let remembered = known[identity] ?? ProcessFacts()
        seen[identity] = remembered
        return remembered
    }

    private mutating func store(_ facts: ProcessFacts, for processID: Int32) {
        if let identity = identity(processID) {
            seen[identity] = facts
        }
    }

    private func identity(_ processID: Int32) -> ProcessIdentity? {
        basics[processID].map { ProcessIdentity(processID: processID, startedAt: $0.startedAt) }
    }
}

/// What the kernel says about a process in one cheap call, asked of every process on the
/// machine.
struct ProcessBasics: Equatable, Sendable {
    let parentProcessID: Int32
    let userID: uid_t
    /// Microseconds since 1970.
    let startedAt: UInt64
    /// The kernel's short name, at most 16 bytes.
    let commandName: String
}

struct ProcessUsage: Equatable, Sendable {
    let footprint: UInt64
    let resident: UInt64
    let cpuTime: TimeInterval
    let finishedChildrenCPUTime: TimeInterval
}

/// The kernel, as functions a test can replace.
struct ProcessKernel: Sendable {
    var listProcessIDs: @Sendable () -> [Int32]
    var basics: @Sendable (Int32) -> ProcessBasics?
    var executablePath: @Sendable (Int32) -> String?
    var arguments: @Sendable (Int32) -> [String]?
    var environmentValues: @Sendable (Int32, Set<String>) -> [String: String]
    var workingDirectory: @Sendable (Int32) -> String?
    var usage: @Sendable (Int32) -> ProcessUsage?
    var machineMemory: @Sendable () -> MachineMemory?
    var ownProcessID: Int32
    var userID: uid_t
    /// Where installed applications live, each ending in a slash.
    var applicationFolders: [String]

    static let live = ProcessKernel(
        listProcessIDs: { AgentProcessScanner.allProcessIDs() },
        basics: { liveBasics(of: $0) },
        executablePath: { AgentProcessLocator.executablePath(for: $0) },
        arguments: { AgentProcessLocator.commandArguments(of: $0) },
        environmentValues: { AgentProcessLocator.environmentValues(of: $0, named: $1) },
        workingDirectory: { AgentProcessLocator.workingDirectoryPath(of: $0) },
        usage: { liveUsage(of: $0) },
        machineMemory: { liveMachineMemory() },
        ownProcessID: getpid(),
        userID: getuid(),
        applicationFolders: [
            "/Applications/", "/System/Applications/",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/",
        ]
    )

    private static func liveBasics(of processID: Int32) -> ProcessBasics? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        let commandName = withUnsafeBytes(of: &info.pbi_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return ProcessBasics(
            parentProcessID: Int32(bitPattern: info.pbi_ppid),
            userID: info.pbi_uid,
            startedAt: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            commandName: commandName
        )
    }

    /// `proc_pid_rusage`, which answers for any process of the same user without root.
    ///
    /// Its times are in Mach ticks, not nanoseconds: on Apple silicon one tick is 125/3 ns,
    /// so a figure read as nanoseconds is 41 times too small.
    private static func liveUsage(of processID: Int32) -> ProcessUsage? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else {
            return nil
        }
        return ProcessUsage(
            footprint: info.ri_phys_footprint,
            resident: info.ri_resident_size,
            cpuTime: seconds(fromTicks: info.ri_user_time + info.ri_system_time),
            finishedChildrenCPUTime: seconds(fromTicks: info.ri_child_user_time + info.ri_child_system_time)
        )
    }

    private static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    private static func seconds(fromTicks ticks: UInt64) -> TimeInterval {
        Double(ticks) * nanosecondsPerTick / 1_000_000_000
    }

    private static func liveMachineMemory() -> MachineMemory? {
        var physical: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &physical, &size, nil, 0) == 0 else {
            return nil
        }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        let pressure: MemoryPressure? =
            sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
            ? memoryPressure(level: level) : nil
        return MachineMemory(
            physical: physical,
            swapUsed: hasSwap ? swap.xsu_used : 0,
            swapTotal: hasSwap ? swap.xsu_total : 0,
            pressure: pressure
        )
    }

    /// The kernel's levels are bits: 1 normal, 2 warning, 4 critical.
    static func memoryPressure(level: Int32) -> MemoryPressure? {
        switch level {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }
}
