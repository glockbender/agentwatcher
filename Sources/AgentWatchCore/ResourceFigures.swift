import Foundation

/// Memory and processor load of a group of processes, as a figure is shown: the agents beside
/// the menu's summary, one line of the machine's total.
public struct ResourceFigure: Equatable, Sendable {
    /// Bytes of footprint — the number Activity Monitor shows (ADR-0024).
    public let footprint: UInt64
    /// Cores busy, 1 being one core fully used, or `nil` until a report has a previous one to
    /// count from.
    public let cpuLoad: Double?

    public init(footprint: UInt64, cpuLoad: Double?) {
        self.footprint = footprint
        self.cpuLoad = cpuLoad
    }
}

extension ResourceReport {
    /// Every row and every shared host with what they run — agents, MCP servers, commands and
    /// orphans. The desktop applications' own processes and what closed sessions left are
    /// counted apart, in `machineFigure`.
    public var agents: ResourceFigure {
        var usage = totals.agents
        usage.add(totals.helpers)
        usage.add(totals.commands)
        usage.add(totals.orphans)
        let loads = sessions.values.compactMap(\.cpuLoad) + hosts.compactMap(\.cpuLoad)
        return ResourceFigure(footprint: usage.footprint, cpuLoad: loads.isEmpty ? nil : loads.reduce(0, +))
    }

    /// The machine's memory in use and its load, split into the agents, their desktop
    /// applications, Agent Watch, what closed sessions left, and everything else. `nil` until
    /// the machine's memory in use could be read.
    public var machineFigure: MachineFigure? {
        guard let machine, let used = machine.used else {
            return nil
        }
        let applicationLoads = applications.compactMap(\.cpuLoad)
        let applications = ResourceFigure(
            footprint: applications.reduce(0) { $0 + $1.total.footprint },
            cpuLoad: applicationLoads.isEmpty ? nil : applicationLoads.reduce(0, +))
        let own = agentWatch.map { ResourceFigure(footprint: $0.footprint, cpuLoad: agentWatchLoad) }
        let leftBehind = ResourceFigure(footprint: totals.unattributed.footprint, cpuLoad: nil)
        let counted = agents.footprint + applications.footprint + (own?.footprint ?? 0) + leftBehind.footprint
        let countedLoad = (agents.cpuLoad ?? 0) + (applications.cpuLoad ?? 0) + (agentWatchLoad ?? 0)
        return MachineFigure(
            physical: machine.physical,
            used: used,
            swapUsed: machine.swapUsed,
            pressure: machine.pressure,
            cores: processor?.cores,
            load: machineLoad,
            agents: agents,
            applications: applications,
            agentWatch: own,
            leftBehind: leftBehind,
            // Footprint counts compressed and swapped memory whole, so the parts can add up to
            // more than is in use; the rest is then nothing rather than less than nothing.
            everythingElse: ResourceFigure(
                footprint: used > counted ? used - counted : 0,
                cpuLoad: machineLoad.map { max(0, $0 - countedLoad) })
        )
    }
}

extension SessionResources {
    /// The session's total, as its row and its card show it.
    public var figure: ResourceFigure {
        ResourceFigure(footprint: total.footprint, cpuLoad: cpuLoad)
    }

    /// Whether the agent's own process is in this session. A Codex thread in ChatGPT.app has
    /// none: the agent is the app's shared process, so the row holds only the thread's commands.
    public var hasAgentProcess: Bool {
        parts[.agent] != nil
    }

    /// The parts that hold memory, heaviest first. Finished commands hold none, and a part at
    /// zero says nothing a reader can use. Ties go by name, so the order does not change
    /// between two reports with the same numbers.
    public func heaviestParts(_ count: Int) -> [(part: ResourcePart, usage: ResourceUsage)] {
        parts
            .filter { $0.value.footprint > 0 }
            .sorted {
                $0.value.footprint != $1.value.footprint
                    ? $0.value.footprint > $1.value.footprint
                    : ResourceFormat.name(of: $0.key) < ResourceFormat.name(of: $1.key)
            }
            .prefix(count)
            .map { (part: $0.key, usage: $0.value) }
    }
}

/// The whole machine, as the Resources page shows it.
public struct MachineFigure: Equatable, Sendable {
    public let physical: UInt64
    public let used: UInt64
    public let swapUsed: UInt64
    public let pressure: MemoryPressure?
    public let cores: Int?
    public let load: Double?
    public let agents: ResourceFigure
    /// Claude.app's and ChatGPT.app's own processes.
    public let applications: ResourceFigure
    public let agentWatch: ResourceFigure?
    /// Processes whose environment names a session that is closed or unknown. Memory only.
    public let leftBehind: ResourceFigure
    public let everythingElse: ResourceFigure

    public init(
        physical: UInt64, used: UInt64, swapUsed: UInt64, pressure: MemoryPressure?, cores: Int?, load: Double?,
        agents: ResourceFigure, applications: ResourceFigure, agentWatch: ResourceFigure?,
        leftBehind: ResourceFigure, everythingElse: ResourceFigure
    ) {
        self.physical = physical
        self.used = used
        self.swapUsed = swapUsed
        self.pressure = pressure
        self.cores = cores
        self.load = load
        self.agents = agents
        self.applications = applications
        self.agentWatch = agentWatch
        self.leftBehind = leftBehind
        self.everythingElse = everythingElse
    }
}

/// How a figure is written wherever it is shown, so the menu, the settings and the debug log
/// agree.
public enum ResourceFormat {
    /// Binary units, as Activity Monitor counts them: «830 MB», «3.4 GB».
    public static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        return megabytes >= 1024
            ? String(format: "%.1f GB", megabytes / 1024)
            : String(format: "%.0f MB", megabytes)
    }

    /// Percent of one core, as Activity Monitor's «% CPU» counts it: two busy cores are 200%.
    public static func load(_ cores: Double) -> String {
        "\(percent(cores)) CPU"
    }

    /// «140%»: the load without its unit, where a symbol beside it says what it is.
    public static func percent(_ cores: Double) -> String {
        String(format: "%.0f%%", max(0, cores) * 100)
    }

    /// What a part of a session is called in a card: «agent», an MCP server by its own name.
    public static func name(of part: ResourcePart) -> String {
        switch part {
        case .agent: "agent"
        case let .helper(name): name
        case .commands: "commands"
        case .finishedCommands: "finished commands"
        case .orphans: "left running"
        }
    }

    /// «3.4 GB · 140% CPU», or the memory alone before the load is known.
    public static func short(_ figure: ResourceFigure) -> String {
        guard let load = figure.cpuLoad else {
            return memory(figure.footprint)
        }
        return "\(memory(figure.footprint)) · \(self.load(load))"
    }

    /// «310% of 1400%»: the machine's load beside what all its cores could give.
    public static func share(_ cores: Double, of total: Int?) -> String {
        let busy = percent(cores)
        guard let total else {
            return busy
        }
        return "\(busy) of \(total * 100)%"
    }

    /// «37.4 GB of 48.0 GB», with the swap and a pressure above normal when there are.
    public static func memoryInUse(_ machine: MachineFigure) -> String {
        var parts = ["\(memory(machine.used)) of \(memory(machine.physical))"]
        if machine.swapUsed > 0 {
            parts.append("\(memory(machine.swapUsed)) swap")
        }
        switch machine.pressure {
        case .warning: parts.append("pressure high")
        case .critical: parts.append("pressure critical")
        case .normal, nil: break
        }
        return parts.joined(separator: " · ")
    }

    /// What a screen reader says for the same figure.
    public static func spoken(_ figure: ResourceFigure) -> String {
        guard let load = figure.cpuLoad else {
            return "Agents use \(memory(figure.footprint)) of memory"
        }
        return "Agents use \(memory(figure.footprint)) of memory and \(self.load(load))"
    }
}
