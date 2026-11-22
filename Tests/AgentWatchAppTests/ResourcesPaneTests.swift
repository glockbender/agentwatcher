import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// What the Resources page says, and that its switches reach the application.
@MainActor
final class ResourcesPaneTests: XCTestCase {
    private let megabyte: UInt64 = 1 << 20

    /// The same two lines whatever the state, so nothing moves when watching is switched.
    func testLinesStayPutAndSayWhyThereIsNoFigure() {
        XCTAssertEqual(
            ResourcesPane.lines(report: nil, isOn: false).map(\.value), ["Off", "Off"])
        XCTAssertEqual(
            ResourcesPane.lines(report: nil, isOn: true).map(\.value), ["Reading…", "Reading…"])
        XCTAssertEqual(
            ResourcesPane.lines(report: nil, isOn: true).map(\.title), ["Agents", "Agent Watch"])
    }

    func testLinesShowTheAgentsAndAgentWatchApart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func table(at seconds: TimeInterval, agentTime: TimeInterval, ownTime: TimeInterval) -> ProcessTable {
            ProcessTable(
                sampledAt: start.addingTimeInterval(seconds),
                processes: [
                    SampledProcess(
                        processID: 100, parentProcessID: 1, name: "claude", footprint: 300 * megabyte,
                        cpuTime: agentTime)
                ],
                agentWatch: ResourceUsage(footprint: 83 * megabyte, cpuTime: ownTime, processCount: 1))
        }
        let row = SessionSnapshot(
            id: SessionSnapshot.id(source: .claude, sessionLabel: "a"), source: .claude, arrivalIndex: 0,
            phase: .idle, lastObservedAt: start, agentProcessID: 100)
        let first = ResourceAttribution.report(
            table: table(at: 0, agentTime: 10, ownTime: 1), sessions: [row], previous: nil)
        let second = ResourceAttribution.report(
            table: table(at: 5, agentTime: 12.5, ownTime: 1.05), sessions: [row], previous: first)

        XCTAssertEqual(
            ResourcesPane.lines(report: second, isOn: true),
            [
                ResourcesPane.Line(title: "Agents", value: "300 MB · 50% CPU"),
                ResourcesPane.Line(title: "Agent Watch", value: "83 MB · 1% CPU"),
            ])
    }

    func testSwitchesReachTheApplication() throws {
        let host = FakeAppHost()
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let model = SettingsModel(
            themes: ThemeStore(preferences: preferences, folder: nil), settings: settings,
            rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: host, version: nil)
        let revision = model.revision

        model.watchesResources = true
        model.showsResourcesInMenu = false

        XCTAssertTrue(host.watchesResources)
        XCTAssertFalse(host.showsResourcesInMenu)
        XCTAssertEqual(model.revision, revision + 2, "each switch redraws the page")
    }
}
