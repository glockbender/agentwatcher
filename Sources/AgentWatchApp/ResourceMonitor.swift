import AgentWatchCore
import AgentWatchLookup
import Foundation

/// Whether the app watches what the agents cost.
///
/// Off until a person turns it on: it adds a timer that runs as long as any row is open, and
/// later figures in the menu and the widget. Until the settings window has a switch for it,
/// it is turned on in `settings.json` and read at launch. `docs/proposals/resource-usage.md`,
/// «Что решить до начала».
final class ResourceSettings: PreferenceDefaults {
    private enum Key {
        static let enabled = "resources.enabled"
    }

    private let preferences: PreferenceFile

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    var defaultValues: [String: JSONValue] {
        [Key.enabled: .bool(false)]
    }

    var isEnabled: Bool {
        preferences.flag(forKey: Key.enabled) ?? false
    }
}

/// Samples what the agents cost, every five seconds while it is on and a row is open.
///
/// A pass runs off the main thread: the first one reads the environment of every process of
/// the person's that lost its parent, and that is tens of milliseconds. The sampler is a value
/// handed to the pass and back, so one pass runs at a time and nothing is shared between
/// threads. The report is kept here and never written into a row: a figure that changes every
/// five seconds would make every row look changed, and the widget redraws a row only when it
/// changed.
@MainActor
final class ResourceMonitor {
    static let interval: TimeInterval = 5
    /// How often a report goes into the debug log. The log keeps a few hundred lines, and a line
    /// per pass would push the events out of it within the hour.
    static let logInterval: TimeInterval = 60

    private(set) var report: ResourceReport?
    var onReport: ((ResourceReport) -> Void)?
    var onLog: ((String) -> Void)?

    private var isEnabled: Bool
    private var sessions: [SessionSnapshot] = []
    /// `nil` while a pass holds it.
    private var sampler: ProcessResourceSampler? = ProcessResourceSampler()
    private var timer: Timer?
    private var lastLoggedAt: Date?
    private let now: () -> Date

    init(isEnabled: Bool, now: @escaping () -> Date = Date.init) {
        self.isEnabled = isEnabled
        self.now = now
    }

    /// Whether there is anything to sample: the monitor is on and a row is still open. A Codex
    /// thread in ChatGPT.app counts without a process of its own — its commands are found under
    /// the application's shared host.
    static func shouldSample(isEnabled: Bool, sessions: some Collection<SessionSnapshot>) -> Bool {
        isEnabled && sessions.contains { $0.phase != .sessionClosed }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            report = nil
            lastLoggedAt = nil
        }
        updateTimer()
    }

    func sessionsChanged(_ sessions: [SessionSnapshot]) {
        self.sessions = sessions
        updateTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTimer() {
        guard Self.shouldSample(isEnabled: isEnabled, sessions: sessions) else {
            stop()
            return
        }
        guard timer == nil else {
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleNow()
            }
        }
        // Lets macOS fold this wake-up into others.
        timer.tolerance = 1
        self.timer = timer
        sampleNow()
    }

    private func sampleNow() {
        guard Self.shouldSample(isEnabled: isEnabled, sessions: sessions), let sampler else {
            return
        }
        self.sampler = nil
        let open = sessions.filter { $0.phase != .sessionClosed }
        let roots = ResourceAttribution.rootProcessIDs(of: open)
        let previous = report
        let moment = now()
        Task.detached(priority: .utility) { [sampler] in
            var sampler = sampler
            let started = DispatchTime.now().uptimeNanoseconds
            let table = sampler.sample(rootProcessIDs: roots, at: moment)
            let report = ResourceAttribution.report(table: table, sessions: open, previous: previous)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            await MainActor.run { [weak self, sampler] in
                self?.finish(report, sampler: sampler, milliseconds: milliseconds)
            }
        }
    }

    private func finish(_ report: ResourceReport, sampler: ProcessResourceSampler, milliseconds: Double) {
        self.sampler = sampler
        guard isEnabled else {
            return
        }
        self.report = report
        onReport?(report)
        if lastLoggedAt.map({ report.sampledAt.timeIntervalSince($0) >= Self.logInterval }) ?? true {
            lastLoggedAt = report.sampledAt
            onLog?(Self.summary(of: report, milliseconds: milliseconds))
        }
    }

    /// One line for the debug log. Figures only: no path, no name of a project.
    static func summary(of report: ResourceReport, milliseconds: Double) -> String {
        let sessionTotal = report.sessions.values.reduce(into: ResourceUsage.zero) { $0.add($1.total) }
        let hostTotal = report.hosts.reduce(into: ResourceUsage.zero) { $0.add($1.total) }
        let loads = report.sessions.values.compactMap(\.cpuLoad) + report.hosts.compactMap(\.cpuLoad)
        var parts = [
            "Resources · \(report.sessions.count) sessions \(bytes(sessionTotal.footprint))",
            "shared hosts \(bytes(hostTotal.footprint))",
            "helpers \(bytes(report.totals.helpers.footprint))",
            "commands \(bytes(report.totals.commands.footprint))",
            "unattributed \(bytes(report.totals.unattributed.footprint))",
        ]
        if !loads.isEmpty {
            parts.append(String(format: "%.2f cores", loads.reduce(0, +)))
        }
        if let own = report.agentWatch {
            parts.append("Agent Watch \(bytes(own.footprint))")
        }
        if let machine = report.machine, machine.swapTotal > 0 {
            parts.append("swap \(bytes(machine.swapUsed)) of \(bytes(machine.swapTotal))")
        }
        parts.append(String(format: "pass %.1f ms", milliseconds))
        return parts.joined(separator: " · ")
    }

    private static func bytes(_ count: UInt64) -> String {
        let megabytes = Double(count) / 1_048_576
        return megabytes >= 1024
            ? String(format: "%.1f GB", megabytes / 1024)
            : String(format: "%.0f MB", megabytes)
    }
}
