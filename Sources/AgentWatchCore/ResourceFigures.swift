import Foundation

/// What the agents cost together: the figure the menu puts beside its summary.
public struct AgentsResourceFigure: Equatable, Sendable {
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
    /// orphans — and nothing that no row answers to: that part is the machine's, and it grows
    /// as the sampler learns to see more of the machine.
    public var agents: AgentsResourceFigure {
        var usage = totals.agents
        usage.add(totals.helpers)
        usage.add(totals.commands)
        usage.add(totals.orphans)
        let loads = sessions.values.compactMap(\.cpuLoad) + hosts.compactMap(\.cpuLoad)
        return AgentsResourceFigure(footprint: usage.footprint, cpuLoad: loads.isEmpty ? nil : loads.reduce(0, +))
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
        String(format: "%.0f%% CPU", max(0, cores) * 100)
    }

    /// «3.4 GB · 140% CPU», or the memory alone before the load is known.
    public static func short(_ figure: AgentsResourceFigure) -> String {
        guard let load = figure.cpuLoad else {
            return memory(figure.footprint)
        }
        return "\(memory(figure.footprint)) · \(self.load(load))"
    }

    /// What a screen reader says for the same figure.
    public static func spoken(_ figure: AgentsResourceFigure) -> String {
        guard let load = figure.cpuLoad else {
            return "Agents use \(memory(figure.footprint)) of memory"
        }
        return "Agents use \(memory(figure.footprint)) of memory and \(self.load(load))"
    }
}
