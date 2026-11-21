import Foundation
import XCTest

@testable import AgentWatchCore

/// Which session a process's memory and processor time belong to, and how the time becomes a
/// load. The rules are listed on `ResourceAttribution`; each test here holds one of them.
final class ResourceAttributionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let megabyte: UInt64 = 1 << 20

    // MARK: - Parts of a session

    func testSessionSplitsIntoAgentHelpersCommandsAndFinishedCommands() {
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(100, parent: 1, "claude", megabytes: 237, cpu: 600, finished: 30),
                process(101, parent: 100, "plata-mcp", megabytes: 200, cpu: 20),
                process(102, parent: 101, "node", megabytes: 10, cpu: 1),
                process(103, parent: 100, "zsh", megabytes: 2, cpu: 1),
                process(104, parent: 103, "go", megabytes: 50, cpu: 40),
            ]
        )

        let report = ResourceAttribution.report(table: table, sessions: [row("a", processID: 100)], previous: nil)
        let session = report.sessions["claude:a"]

        XCTAssertEqual(session?.parts[.agent], usage(megabytes: 237, cpu: 600, processes: 1))
        XCTAssertEqual(session?.parts[.helper("plata-mcp")], usage(megabytes: 210, cpu: 21, processes: 2))
        XCTAssertEqual(session?.parts[.commands], usage(megabytes: 52, cpu: 41, processes: 2))
        XCTAssertEqual(session?.parts[.finishedCommands], usage(megabytes: 0, cpu: 30, processes: 0))
        XCTAssertEqual(session?.total, usage(megabytes: 499, cpu: 692, processes: 5))
        XCTAssertNil(session?.cpuLoad, "a first report has nothing to measure a load against")
    }

    /// A `claude -p` started from a session's shell inherits that session's marker. Its own
    /// commands are still its own: the nearest root above a process decides, not the marker.
    func testNestedRowKeepsItsProcessesThoughTheyInheritedTheParentsMarker() {
        let parent = marker("a")
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(100, parent: 1, "claude", megabytes: 200),
                process(101, parent: 100, "zsh", megabytes: 2, markers: [parent]),
                process(102, parent: 101, "claude", megabytes: 150, markers: [parent]),
                process(103, parent: 102, "zsh", megabytes: 3, markers: [parent]),
            ]
        )

        let report = ResourceAttribution.report(
            table: table,
            sessions: [row("a", processID: 100), row("b", processID: 102, index: 1)],
            previous: nil
        )

        XCTAssertEqual(report.sessions["claude:a"]?.total.processCount, 2)
        XCTAssertEqual(report.sessions["claude:a"]?.parts[.commands]?.footprint, 2 * megabyte)
        XCTAssertEqual(report.sessions["claude:b"]?.parts[.agent]?.footprint, 150 * megabyte)
        XCTAssertEqual(report.sessions["claude:b"]?.parts[.commands]?.footprint, 3 * megabyte)
    }

    // MARK: - Orphans

    func testOrphanBelongsToTheRowItsMarkerNamesAndTakesItsChildrenAlong() {
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(100, parent: 1, "claude", megabytes: 200),
                process(200, parent: 1, "node", megabytes: 80, markers: [marker("a")]),
                process(201, parent: 200, "node", megabytes: 20),
            ]
        )

        let report = ResourceAttribution.report(table: table, sessions: [row("a", processID: 100)], previous: nil)

        XCTAssertEqual(report.sessions["claude:a"]?.parts[.orphans], usage(megabytes: 100, cpu: 0, processes: 2))
        XCTAssertEqual(report.totals.orphans.processCount, 2)
    }

    func testOrphanOfAClosedOrUnknownRowIsUnattributed() {
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(300, parent: 1, "node", megabytes: 10, markers: [marker("closed")]),
                process(301, parent: 1, "node", megabytes: 20, markers: [marker("nobody")]),
                process(302, parent: 1, "claude", megabytes: 30),
            ]
        )

        let report = ResourceAttribution.report(
            table: table,
            sessions: [row("closed", processID: 302, phase: .sessionClosed)],
            previous: nil
        )

        XCTAssertTrue(report.sessions.isEmpty, "a closed row is neither a root nor a marker's answer")
        XCTAssertEqual(report.totals.unattributed, usage(megabytes: 60, cpu: 0, processes: 3))
    }

    /// The engine sends a copy's events to the row it continues; a marker naming the copy goes
    /// the same way.
    func testMarkerOfACopyResolvesToTheRowItContinues() {
        var original = row("a", processID: 100)
        original.continuedBy = ["a-copy"]
        let table = ProcessTable(
            sampledAt: start,
            processes: [process(200, parent: 1, "node", megabytes: 5, markers: [marker("a-copy")])]
        )

        let report = ResourceAttribution.report(table: table, sessions: [original], previous: nil)

        XCTAssertEqual(report.sessions["claude:a"]?.parts[.orphans]?.processCount, 1)
    }

    // MARK: - A shared host

    /// The shell under `app-server` shows no environment, and the thread's identifier is on the
    /// command under it: `docs/agent-processes.md`, «Маркер сессии в окружении».
    func testHostSplitsCommandsByThreadAndGroupsHelpersByFolder() {
        let thread = marker("t1", source: .codex)
        let closedThread = marker("t2", source: .codex)
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(500, parent: 1, "codex", megabytes: 1100, cpu: 100, finished: 900),
                process(501, parent: 500, "zsh", megabytes: 2, cpu: 1),
                process(502, parent: 501, "go", megabytes: 40, cpu: 9, markers: [thread]),
                process(503, parent: 500, "plata-mcp", megabytes: 300, workingDirectory: "/p/agent-watch"),
                process(504, parent: 500, "plata-mcp", megabytes: 310, workingDirectory: "/p/agent-watch"),
                process(505, parent: 500, "plata-mcp", megabytes: 290, workingDirectory: "/p/devx"),
                process(506, parent: 500, "zsh", megabytes: 2),
                process(507, parent: 500, "zsh", megabytes: 2),
                process(508, parent: 507, "python3", megabytes: 30, markers: [closedThread]),
            ],
            hosts: [SharedAgentHost(processID: 500, source: .codex)]
        )

        let report = ResourceAttribution.report(
            table: table,
            sessions: [row("t1", source: .codex), row("t2", source: .codex, index: 1, phase: .sessionClosed)],
            previous: nil
        )
        let host = report.hosts.first

        XCTAssertEqual(report.sessions["codex:t1"]?.parts[.commands], usage(megabytes: 42, cpu: 10, processes: 2))
        XCTAssertEqual(host?.parts[.host], usage(megabytes: 1100, cpu: 1000, processes: 1))
        XCTAssertEqual(
            host?.parts[.helper(name: "plata-mcp", workingDirectory: "/p/agent-watch")]?.footprint,
            610 * megabyte)
        XCTAssertEqual(host?.parts[.helper(name: "plata-mcp", workingDirectory: "/p/devx")]?.processCount, 1)
        XCTAssertEqual(host?.parts[.unclaimedCommands], usage(megabytes: 34, cpu: 0, processes: 3))
    }

    // MARK: - Every process once

    func testEveryProcessLandsInExactlyOneBucket() {
        let thread = marker("t1", source: .codex)
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(100, parent: 1, "claude", megabytes: 200, cpu: 10, finished: 5),
                process(101, parent: 100, "plata-mcp", megabytes: 160, cpu: 2),
                process(102, parent: 100, "zsh", megabytes: 2, cpu: 1),
                process(200, parent: 1, "node", megabytes: 50, markers: [marker("a")]),
                process(300, parent: 1, "node", megabytes: 7, markers: [marker("gone")]),
                process(500, parent: 1, "codex", megabytes: 900, cpu: 50, finished: 70),
                process(501, parent: 500, "zsh", megabytes: 2),
                process(502, parent: 501, "go", megabytes: 40, cpu: 3, markers: [thread]),
                process(503, parent: 500, "plata-mcp", megabytes: 300, workingDirectory: "/p"),
            ],
            hosts: [SharedAgentHost(processID: 500, source: .codex)]
        )

        let report = ResourceAttribution.report(
            table: table,
            sessions: [row("a", processID: 100), row("t1", source: .codex, index: 1)],
            previous: nil
        )
        var buckets = report.totals.unattributed
        report.sessions.values.forEach { buckets.add($0.total) }
        report.hosts.forEach { buckets.add($0.total) }

        XCTAssertEqual(report.totals.all.processCount, table.processes.count)
        XCTAssertEqual(report.totals.all.footprint, table.processes.reduce(0) { $0 + $1.footprint })
        XCTAssertEqual(buckets, report.totals.all)
    }

    // MARK: - Load

    /// A command that ends moves its time into the agent's counter of finished children. The
    /// session's time keeps counting through that move; only the second of real work shows.
    func testLoadIsTheSessionsTimeOverTheInterval() {
        let sessions = [row("a", processID: 100)]
        let first = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start,
                processes: [
                    process(100, parent: 1, "claude", cpu: 10),
                    process(101, parent: 100, "zsh", cpu: 5),
                ]),
            sessions: sessions,
            previous: nil
        )
        let second = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start.addingTimeInterval(5),
                processes: [process(100, parent: 1, "claude", cpu: 11, finished: 6)]),
            sessions: sessions,
            previous: first
        )

        XCTAssertEqual(second.sessions["claude:a"]?.cpuLoad ?? -1, 0.4, accuracy: 0.0001)
    }

    func testLoadReadsIdleWhenTimeLeftTheTreeUnreaped() {
        let sessions = [row("a", processID: 100)]
        let first = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start,
                processes: [
                    process(100, parent: 1, "claude", cpu: 10),
                    process(101, parent: 100, "node", cpu: 30),
                ]),
            sessions: sessions,
            previous: nil
        )
        let second = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start.addingTimeInterval(5),
                processes: [process(100, parent: 1, "claude", cpu: 10)]),
            sessions: sessions,
            previous: first
        )

        XCTAssertEqual(second.sessions["claude:a"]?.cpuLoad, 0)
    }

    /// A nested row's root that ends is reaped by its parent session's shell, and its whole
    /// life lands in that shell's counter at once. The parent's load must not show it: the time
    /// was the nested row's, and its load already did.
    func testReapedNestedRowDoesNotSpikeTheSessionThatReapedIt() {
        let sessions = [row("a", processID: 100), row("b", processID: 102, index: 1)]
        let first = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start,
                processes: [
                    process(100, parent: 1, "claude", cpu: 10),
                    process(101, parent: 100, "zsh", cpu: 1),
                    process(102, parent: 101, "claude", cpu: 50),
                ]),
            sessions: sessions,
            previous: nil
        )
        let second = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start.addingTimeInterval(5),
                processes: [
                    process(100, parent: 1, "claude", cpu: 10),
                    process(101, parent: 100, "zsh", cpu: 1, finished: 51),
                ]),
            sessions: sessions,
            previous: first
        )

        XCTAssertEqual(second.sessions["claude:a"]?.cpuLoad ?? -1, 0.2, accuracy: 0.0001)
    }

    /// A thread's command under `app-server` is reaped by the host when it ends, and its time
    /// lands in the host's counter — after the thread's row already showed it. The host must
    /// not show it a second time.
    func testThreadCommandThatEndsDoesNotSpikeTheHostThatReapedIt() {
        let sessions = [row("t1", source: .codex)]
        let hosts = [SharedAgentHost(processID: 500, source: .codex)]
        let first = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start,
                processes: [
                    process(500, parent: 1, "codex", cpu: 100),
                    process(501, parent: 500, "zsh", cpu: 1),
                    process(502, parent: 501, "go", cpu: 9, markers: [marker("t1", source: .codex)]),
                ],
                hosts: hosts),
            sessions: sessions,
            previous: nil
        )
        let second = ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start.addingTimeInterval(5),
                processes: [process(500, parent: 1, "codex", cpu: 100, finished: 10)],
                hosts: hosts),
            sessions: sessions,
            previous: first
        )

        XCTAssertEqual(second.hosts.first?.cpuLoad, 0)
    }

    // MARK: - A background session's terminal

    /// After `/bg` the terminal the person typed it in keeps an interactive `claude` alive,
    /// with MCP servers of its own, showing the session. Its cost is the session's.
    /// The sampler is handed the same roots attribution splits by, or a viewer's helpers would
    /// never reach the table.
    func testARowsTreeStartsAtItsAgentAndItsViewerWhileItIsOpen() {
        var background = row("a", processID: 100)
        background.viewerProcessID = 200
        let closed = row("b", processID: 300, phase: .sessionClosed)
        let desktopThread = row("t", source: .codex)

        XCTAssertEqual(ResourceAttribution.rootProcessIDs(of: background), [100, 200])
        XCTAssertEqual(ResourceAttribution.rootProcessIDs(of: [background, closed, desktopThread]), [100, 200])
    }

    func testViewerOfABackgroundSessionCountsAsTheSessions() {
        var background = row("a", processID: 100)
        background.viewerProcessID = 200
        let table = ProcessTable(
            sampledAt: start,
            processes: [
                process(100, parent: 1, "claude", megabytes: 300),
                process(200, parent: 1, "claude", megabytes: 200),
                process(201, parent: 200, "plata-mcp", megabytes: 160),
            ]
        )

        let report = ResourceAttribution.report(table: table, sessions: [background], previous: nil)

        XCTAssertEqual(report.sessions["claude:a"]?.parts[.agent]?.footprint, 500 * megabyte)
        XCTAssertEqual(report.sessions["claude:a"]?.parts[.helper("plata-mcp")]?.processCount, 1)
        XCTAssertEqual(report.totals.unattributed.processCount, 0)
    }

    // MARK: - Fixtures

    private func row(
        _ label: String,
        source: AgentSource = .claude,
        processID: Int32? = nil,
        index: Int = 0,
        phase: SessionPhase = .idle
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionSnapshot.id(source: source, sessionLabel: label),
            source: source,
            arrivalIndex: index,
            phase: phase,
            lastObservedAt: start,
            agentProcessID: processID
        )
    }

    private func marker(_ label: String, source: AgentSource = .claude) -> SessionMarker {
        SessionMarker(source: source, label: label)
    }

    private func process(
        _ processID: Int32,
        parent: Int32,
        _ name: String,
        megabytes: UInt64 = 0,
        cpu: TimeInterval = 0,
        finished: TimeInterval = 0,
        markers: [SessionMarker] = [],
        workingDirectory: String? = nil
    ) -> SampledProcess {
        SampledProcess(
            processID: processID,
            parentProcessID: parent,
            name: name,
            footprint: megabytes * megabyte,
            resident: megabytes * megabyte / 2,
            cpuTime: cpu,
            finishedChildrenCPUTime: finished,
            markers: markers,
            workingDirectory: workingDirectory
        )
    }

    private func usage(megabytes: UInt64, cpu: TimeInterval, processes: Int) -> ResourceUsage {
        ResourceUsage(
            footprint: megabytes * megabyte,
            resident: megabytes * megabyte / 2,
            cpuTime: cpu,
            processCount: processes
        )
    }
}
