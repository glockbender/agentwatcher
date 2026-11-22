import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchLookup

/// Not a test: two passes over the real machine, printed, for the person checking the figures
/// against Activity Monitor and the cost of a pass. The rows are the installed app's, read from
/// its memory file, so the sessions are the ones on screen.
///
///     AGENT_WATCH_RESOURCE_PROBE=1 swift test --filter ResourceProbe
final class ResourceProbe: XCTestCase {
    func testTwoPassesOverThisMachine() throws {
        guard ProcessInfo.processInfo.environment["AGENT_WATCH_RESOURCE_PROBE"] != nil else {
            throw XCTSkip("Set AGENT_WATCH_RESOURCE_PROBE to measure this machine")
        }
        let rows = try installedAppRows()
        let open = rows.filter { $0.phase != .sessionClosed }
        let roots = ResourceAttribution.rootProcessIDs(of: open)
        var sampler = ProcessResourceSampler()

        let (firstTable, coldMilliseconds) = timed { sampler.sample(rootProcessIDs: roots, at: Date()) }
        let first = ResourceAttribution.report(table: firstTable, sessions: open, previous: nil)
        Thread.sleep(forTimeInterval: 5)
        let (table, warmMilliseconds) = timed { sampler.sample(rootProcessIDs: roots, at: Date()) }
        let (report, attributionMilliseconds) = timed {
            ResourceAttribution.report(table: table, sessions: open, previous: first)
        }

        var lines = [
            "rows \(rows.count), open \(open.count), with a process \(roots.count)",
            "processes sampled \(table.processes.count), hosts \(table.hosts.map(\.processID))",
            String(
                format: "pass: cold %.1f ms, warm %.1f ms, attribution %.2f ms",
                coldMilliseconds, warmMilliseconds, attributionMilliseconds),
        ]
        let rootOf = Dictionary(
            open.compactMap { row in ResourceAttribution.rootProcessIDs(of: row).first.map { (row.id, $0) } }
        ) { first, _ in first
        }
        for session in report.sessions.values.sorted(by: { $0.total.footprint > $1.total.footprint }) {
            let parts = session.parts.sorted { $0.value.footprint > $1.value.footprint }.prefix(4)
                .map { "\(describe($0.key)) \(megabytes($0.value.footprint))" }
            lines.append(
                "session \(session.sessionID.prefix(16)) root \(rootOf[session.sessionID].map(String.init) ?? "-")"
                    + " footprint \(megabytes(session.total.footprint)) resident \(megabytes(session.total.resident))"
                    + " load \(session.cpuLoad.map { String(format: "%.3f", $0) } ?? "-") · \(parts.joined(separator: ", "))"
            )
        }
        for host in report.hosts {
            let parts = host.parts.sorted { $0.value.footprint > $1.value.footprint }.prefix(6)
                .map { "\(describe($0.key)) \(megabytes($0.value.footprint))/\($0.value.processCount)p" }
            lines.append(
                "host \(host.host.processID) footprint \(megabytes(host.total.footprint))"
                    + " load \(host.cpuLoad.map { String(format: "%.3f", $0) } ?? "-") · \(parts.joined(separator: ", "))"
            )
        }
        lines.append(
            "totals: agents \(megabytes(report.totals.agents.footprint)), helpers \(megabytes(report.totals.helpers.footprint)),"
                + " commands \(megabytes(report.totals.commands.footprint)), orphans \(megabytes(report.totals.orphans.footprint)),"
                + " unattributed \(megabytes(report.totals.unattributed.footprint))/\(report.totals.unattributed.processCount)p"
        )
        lines.append(
            "this test process \(megabytes(report.agentWatch?.footprint ?? 0)); machine \(String(describing: report.machine))"
        )
        for application in report.applications {
            lines.append(
                "application \(application.name) \(megabytes(application.total.footprint))"
                    + "/\(application.total.processCount)p load \(application.cpuLoad.map { String(format: "%.3f", $0) } ?? "-")"
            )
        }
        if let machine = report.machineFigure {
            let figure = { (figure: ResourceFigure) in ResourceFormat.short(figure) }
            lines.append(
                "machine used \(ResourceFormat.memory(machine.used)) of \(ResourceFormat.memory(machine.physical)),"
                    + " load \(machine.load.map { String(format: "%.2f", $0) } ?? "-") of \(machine.cores ?? 0) cores;"
                    + " agents \(figure(machine.agents)), applications \(figure(machine.applications)),"
                    + " left behind \(figure(machine.leftBehind)), everything else \(figure(machine.everythingElse))"
            )
        }
        print(lines.map { "PROBE " + $0 }.joined(separator: "\n"))
    }

    private func installedAppRows() throws -> [SessionSnapshot] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentWatch/sessions-remembered.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let entries = object?["sessions"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard
                let id = entry["id"] as? String,
                let source = (entry["source"] as? String).flatMap(AgentSource.init(rawValue:)),
                let phase = (entry["phase"] as? String).flatMap(SessionPhase.init(rawValue:))
            else {
                return nil
            }
            var row = SessionSnapshot(
                id: id,
                source: source,
                arrivalIndex: entry["arrivalIndex"] as? Int ?? 0,
                phase: phase,
                lastObservedAt: Date(),
                agentProcessID: (entry["agentProcessID"] as? Int).map(Int32.init)
            )
            row.viewerProcessID = (entry["viewerProcessID"] as? Int).map(Int32.init)
            row.continuedBy = entry["continuedBy"] as? [String]
            return row
        }
    }

    private func timed<T>(_ work: () -> T) -> (T, Double) {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = work()
        return (result, Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
    }

    private func megabytes(_ bytes: UInt64) -> String {
        "\(bytes >> 20) MB"
    }

    private func describe(_ part: ResourcePart) -> String {
        switch part {
        case .agent: "agent"
        case let .helper(name): name
        case .commands: "commands"
        case .finishedCommands: "finished"
        case .orphans: "orphans"
        }
    }

    private func describe(_ part: HostPart) -> String {
        switch part {
        case .host: "host"
        case let .helper(name, folder): "\(name)@\(folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-")"
        case .unclaimedCommands: "unclaimed"
        }
    }
}
