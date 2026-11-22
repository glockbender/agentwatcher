import AgentWatchCore
import XCTest

/// The figure the menu shows beside its summary, and how every figure is written.
final class ResourceFiguresTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let megabyte: UInt64 = 1 << 20

    /// Rows and hosts with everything they run count; an orphan that names a closed row does
    /// not — it belongs to no agent the person can see.
    func testAgentsFigureHoldsRowsAndHostsAndLeavesOutWhatNoRowAnswersTo() {
        let closed = SessionMarker(source: .claude, label: "gone")
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(100, parent: 1, "claude", megabytes: 300),
                process(101, parent: 100, "plata-mcp", megabytes: 200),
                process(500, parent: 1, "codex", megabytes: 1000),
                process(501, parent: 500, "plata-mcp", megabytes: 400, workingDirectory: "/p"),
                process(900, parent: 1, "node", megabytes: 700, markers: [closed]),
            ],
            hosts: [SharedAgentHost(processID: 500, source: .codex)]
        )

        let report = ResourceAttribution.report(table: table, sessions: [row("a", processID: 100)], previous: nil)

        XCTAssertEqual(report.agents.footprint, 1900 * megabyte)
        XCTAssertEqual(report.totals.unattributed.footprint, 700 * megabyte)
        XCTAssertNil(report.agents.cpuLoad, "the first report has nothing to count load from")
    }

    func testAgentsLoadIsEveryRowsAndHostsLoadTogether() throws {
        let sessions = [row("a", processID: 100)]
        let hosts = [SharedAgentHost(processID: 500, source: .codex)]
        let first = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start,
                processes: [process(100, parent: 1, "claude", cpu: 10), process(500, parent: 1, "codex", cpu: 50)],
                hosts: hosts),
            sessions: sessions, previous: nil)

        let second = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start.addingTimeInterval(5),
                processes: [process(100, parent: 1, "claude", cpu: 12), process(500, parent: 1, "codex", cpu: 55)],
                hosts: hosts),
            sessions: sessions, previous: first)

        XCTAssertEqual(try XCTUnwrap(second.agents.cpuLoad), 1.4, accuracy: 0.0001)
    }

    func testAgentWatchCountsItsOwnLoadApartFromTheAgents() throws {
        func table(at seconds: TimeInterval, ownTime: TimeInterval) -> ProcessTable {
            ProcessTable(
                sampledAt: start.addingTimeInterval(seconds), processes: [],
                agentWatch: ResourceUsage(footprint: 83 * megabyte, cpuTime: ownTime, processCount: 1))
        }
        let first = ResourceAttribution.report(table: table(at: 0, ownTime: 100), sessions: [], previous: nil)

        let second = ResourceAttribution.report(table: table(at: 5, ownTime: 100.1), sessions: [], previous: first)

        XCTAssertNil(first.agentWatchLoad)
        XCTAssertEqual(try XCTUnwrap(second.agentWatchLoad), 0.02, accuracy: 0.0001)
        XCTAssertEqual(second.agents.footprint, 0, "Agent Watch is not one of the agents")
    }

    func testFiguresAreWrittenAsActivityMonitorWritesThem() {
        XCTAssertEqual(ResourceFormat.memory(830 * megabyte), "830 MB")
        XCTAssertEqual(ResourceFormat.memory(3482 * megabyte), "3.4 GB")
        XCTAssertEqual(ResourceFormat.load(1.4), "140% CPU")
        XCTAssertEqual(ResourceFormat.load(-0.1), "0% CPU")
        XCTAssertEqual(
            ResourceFormat.short(AgentsResourceFigure(footprint: 3482 * megabyte, cpuLoad: 1.4)), "3.4 GB · 140% CPU")
        XCTAssertEqual(ResourceFormat.short(AgentsResourceFigure(footprint: 830 * megabyte, cpuLoad: nil)), "830 MB")
        XCTAssertEqual(
            ResourceFormat.spoken(AgentsResourceFigure(footprint: 830 * megabyte, cpuLoad: 0.25)),
            "Agents use 830 MB of memory and 25% CPU")
    }

    private func row(_ label: String, processID: Int32) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionSnapshot.id(source: .claude, sessionLabel: label),
            source: .claude,
            arrivalIndex: 0,
            phase: .idle,
            lastObservedAt: start,
            agentProcessID: processID
        )
    }

    private func process(
        _ processID: Int32,
        parent: Int32,
        _ name: String,
        megabytes: UInt64 = 0,
        cpu: TimeInterval = 0,
        markers: [SessionMarker] = [],
        workingDirectory: String? = nil
    ) -> SampledProcess {
        SampledProcess(
            processID: processID, parentProcessID: parent, name: name, footprint: megabytes * megabyte,
            cpuTime: cpu, markers: markers, workingDirectory: workingDirectory)
    }
}
