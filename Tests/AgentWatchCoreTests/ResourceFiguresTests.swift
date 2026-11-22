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

    /// Claude.app runs its agents' sessions and its own chat under one tree. A session there is
    /// its row's; everything else under the application — windows, the chat's MCP servers — is
    /// the application's, from each of its processes under `launchd`.
    func testApplicationKeepsWhatNoRowClaimsAndRowsUnderItStayTheirs() throws {
        let claude = DesktopApplication(processID: 50, name: "Claude.app")
        let crashHandler = DesktopApplication(processID: 60, name: "Claude.app")
        func table(at seconds: TimeInterval, appTime: TimeInterval, busy: UInt64, total: UInt64) -> ProcessTable {
            ProcessTable(
                sampledAt: start.addingTimeInterval(seconds),
                processes: [
                    process(50, parent: 1, "Claude", megabytes: 600, cpu: appTime),
                    process(51, parent: 50, "disclaimer", megabytes: 1),
                    process(52, parent: 51, "plata-mcp", megabytes: 200),
                    process(53, parent: 50, "disclaimer", megabytes: 1),
                    process(100, parent: 53, "claude", megabytes: 300),
                    process(101, parent: 100, "plata-mcp", megabytes: 200),
                    process(60, parent: 1, "chrome_crashpad_handler", megabytes: 3),
                ],
                applications: [claude, crashHandler],
                agentWatch: ResourceUsage(footprint: 80 * megabyte, cpuTime: 1, processCount: 1),
                machine: MachineMemory(
                    physical: 48 << 30, used: 10 << 30, swapUsed: 0, swapTotal: 0, pressure: .normal),
                processor: ProcessorTicks(busy: busy, total: total, cores: 10))
        }
        let sessions = [row("a", processID: 100)]
        let first = ResourceAttribution.report(
            table: table(at: 0, appTime: 10, busy: 1000, total: 4000), sessions: sessions, previous: nil)

        let second = ResourceAttribution.report(
            table: table(at: 5, appTime: 11, busy: 1300, total: 5000), sessions: sessions, previous: first)

        XCTAssertEqual(second.sessions["claude:a"]?.total.footprint, 500 * megabyte)
        XCTAssertEqual(second.applications.map(\.name), ["Claude.app"])
        XCTAssertEqual(second.applications.first?.total.footprint, 805 * megabyte)
        XCTAssertEqual(second.applications.first?.total.processCount, 5)
        XCTAssertEqual(try XCTUnwrap(second.applications.first?.cpuLoad), 0.2, accuracy: 0.0001)

        let machine = try XCTUnwrap(second.machineFigure)
        XCTAssertEqual(try XCTUnwrap(machine.load), 3, accuracy: 0.0001, "300 of 1000 ticks busy on 10 cores")
        XCTAssertEqual(machine.applications.footprint, 805 * megabyte)
        XCTAssertEqual(
            machine.agents.footprint + machine.applications.footprint + (machine.agentWatch?.footprint ?? 0)
                + machine.leftBehind.footprint + machine.everythingElse.footprint,
            machine.used, "the parts add up to what is in use")
    }

    /// Compressed and swapped memory count whole in a footprint, so the parts can outgrow what
    /// is in use; the rest is then nothing, never a wrapped-around number.
    func testEverythingElseIsNothingWhenThePartsOutgrowWhatIsInUse() throws {
        let table = ProcessTable(
            sampledAt: start,
            processes: [process(100, parent: 1, "claude", megabytes: 3000)],
            machine: MachineMemory(physical: 8 << 30, used: 2 << 30, swapUsed: 0, swapTotal: 0, pressure: .warning))

        let report = ResourceAttribution.report(table: table, sessions: [row("a", processID: 100)], previous: nil)

        XCTAssertEqual(try XCTUnwrap(report.machineFigure).everythingElse.footprint, 0)
        XCTAssertNil(report.machineFigure?.load)
    }

    func testFiguresAreWrittenAsActivityMonitorWritesThem() {
        XCTAssertEqual(ResourceFormat.memory(830 * megabyte), "830 MB")
        XCTAssertEqual(ResourceFormat.memory(3482 * megabyte), "3.4 GB")
        XCTAssertEqual(ResourceFormat.load(1.4), "140% CPU")
        XCTAssertEqual(ResourceFormat.load(-0.1), "0% CPU")
        XCTAssertEqual(
            ResourceFormat.short(ResourceFigure(footprint: 3482 * megabyte, cpuLoad: 1.4)), "3.4 GB · 140% CPU")
        XCTAssertEqual(ResourceFormat.short(ResourceFigure(footprint: 830 * megabyte, cpuLoad: nil)), "830 MB")
        XCTAssertEqual(
            ResourceFormat.spoken(ResourceFigure(footprint: 830 * megabyte, cpuLoad: 0.25)),
            "Agents use 830 MB of memory and 25% CPU")
        XCTAssertEqual(ResourceFormat.share(3.1, of: 14), "310% of 1400%")
        let machine = MachineFigure(
            physical: 48 << 30, used: 38298 * megabyte, swapUsed: 5 << 30, pressure: .warning, cores: 14, load: 3.1,
            agents: ResourceFigure(footprint: 0, cpuLoad: nil),
            applications: ResourceFigure(footprint: 0, cpuLoad: nil),
            agentWatch: nil, leftBehind: ResourceFigure(footprint: 0, cpuLoad: nil),
            everythingElse: ResourceFigure(footprint: 0, cpuLoad: nil))
        XCTAssertEqual(ResourceFormat.memoryInUse(machine), "37.4 GB of 48.0 GB · 5.0 GB swap · pressure high")
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
