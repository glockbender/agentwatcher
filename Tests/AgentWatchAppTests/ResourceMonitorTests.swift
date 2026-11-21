import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchApp

/// When the resource monitor keeps a timer, and what it writes about a report.
@MainActor
final class ResourceMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    func testItIsOffUntilAPersonTurnsItOn() throws {
        let settings = ResourceSettings(preferences: try isolatedPreferences())

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.defaultValues["resources.enabled"], .bool(false))
    }

    /// No timer while it is off or every row is closed — and a Codex thread in ChatGPT.app is an
    /// open row although no process of its own is known.
    func testItSamplesOnlyWhileOnAndARowIsOpen() {
        let closed = row("a", phase: .sessionClosed)
        let desktopThread = row("t", source: .codex)

        XCTAssertFalse(ResourceMonitor.shouldSample(isEnabled: false, sessions: [desktopThread]))
        XCTAssertFalse(ResourceMonitor.shouldSample(isEnabled: true, sessions: []))
        XCTAssertFalse(ResourceMonitor.shouldSample(isEnabled: true, sessions: [closed]))
        XCTAssertTrue(ResourceMonitor.shouldSample(isEnabled: true, sessions: [closed, desktopThread]))
    }

    /// One real pass over this machine: the test's own process stands in for an agent's, and the
    /// report and one log line come back to the main thread. The first pass starts with the
    /// rows, not with the timer.
    func testFirstPassReportsTheOpenRowAndLogsOnce() async {
        let monitor = ResourceMonitor(isEnabled: true)
        let reported = expectation(description: "a report")
        reported.assertForOverFulfill = false
        var lines: [String] = []
        monitor.onLog = { lines.append($0) }
        monitor.onReport = { _ in reported.fulfill() }

        monitor.sessionsChanged([row("a", processID: getpid())])
        await fulfillment(of: [reported], timeout: 10)
        monitor.stop()

        XCTAssertGreaterThan(monitor.report?.sessions["claude:a"]?.parts[.agent]?.footprint ?? 0, 0)
        XCTAssertEqual(lines.count, 1)
    }

    func testMonitorThatIsOffNeverReports() async {
        let monitor = ResourceMonitor(isEnabled: false)
        let reported = expectation(description: "no report")
        reported.isInverted = true
        monitor.onReport = { _ in reported.fulfill() }

        monitor.sessionsChanged([row("a", processID: getpid())])
        await fulfillment(of: [reported], timeout: 1)

        XCTAssertNil(monitor.report)
    }

    /// The debug log is a file anyone can read and paste into an issue. A helper's folder is a
    /// grouping key and must not reach it.
    func testLogLineCarriesFiguresAndNoFolder() {
        let table = ProcessTable(
            sampledAt: now,
            processes: [
                SampledProcess(processID: 100, parentProcessID: 1, name: "claude", footprint: 200 << 20),
                SampledProcess(processID: 500, parentProcessID: 1, name: "codex", footprint: 3 << 30),
                SampledProcess(
                    processID: 501, parentProcessID: 500, name: "plata-mcp", footprint: 300 << 20,
                    workingDirectory: "/Users/someone/secret-project"),
            ],
            hosts: [SharedAgentHost(processID: 500, source: .codex)],
            agentWatch: ResourceUsage(footprint: 83 << 20, processCount: 1),
            machine: MachineMemory(physical: 48 << 30, swapUsed: 5 << 30, swapTotal: 6 << 30, pressure: .normal)
        )
        let report = ResourceAttribution.report(table: table, sessions: [row("a", processID: 100)], previous: nil)

        let line = ResourceMonitor.summary(of: report, milliseconds: 4.26)

        XCTAssertEqual(
            line,
            "Resources · 1 sessions 200 MB · shared hosts 3.3 GB · helpers 300 MB · commands 0 MB"
                + " · unattributed 0 MB · Agent Watch 83 MB · swap 5.0 GB of 6.0 GB · pass 4.3 ms")
        XCTAssertFalse(line.contains("secret-project"))
    }

    private func row(
        _ label: String,
        source: AgentSource = .claude,
        processID: Int32? = nil,
        phase: SessionPhase = .idle
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionSnapshot.id(source: source, sessionLabel: label),
            source: source,
            arrivalIndex: 0,
            phase: phase,
            lastObservedAt: now,
            agentProcessID: processID
        )
    }
}
