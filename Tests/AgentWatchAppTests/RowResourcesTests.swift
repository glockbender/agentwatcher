import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// A session's memory and CPU in its widget row and its hover card.
///
/// The figures change every five seconds and the row must not: a rebuilt row is a new view, so
/// it loses the pointer resting on it and the card about to open. A reading restates the
/// numbers in the row already on screen, and only switching watching rebuilds a row.
@MainActor
final class RowResourcesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let megabyte: UInt64 = 1 << 20

    func testAReadingRewritesTheNumbersInTheRowAlreadyOnScreen() throws {
        var resources = WidgetResources(isWatching: true, showsInCard: true)
        let controller = try makeController(resourceStyle: .both)
        defer { controller.shutdown() }
        controller.resources = { resources }
        let session = measuredSession(processID: 100)
        controller.render(WidgetState(sessions: [session]))
        let row = try XCTUnwrap(controller.currentRow(for: session.id))
        XCTAssertEqual(row.shownResources, ["–", "–"], "no reading has named the session yet")

        let first = report(footprint: 612 * megabyte, cpuTime: 10, sessions: [session], at: now)
        resources.report = first
        controller.resourcesChanged()
        XCTAssertTrue(controller.currentRow(for: session.id) === row, "a reading rebuilt the row")
        XCTAssertEqual(row.shownResources, ["612 MB", "–"], "the first reading has no load to count from")

        resources.report = report(
            footprint: 1536 * megabyte, cpuTime: 12, sessions: [session], previous: first, at: now.addingTimeInterval(5)
        )
        controller.resourcesChanged()
        XCTAssertTrue(controller.currentRow(for: session.id) === row, "a reading rebuilt the row")
        XCTAssertEqual(row.shownResources, ["1.5 GB", "40%"], "two seconds of CPU over five is 40%")
        XCTAssertFalse(row.refreshResources(resources.figure(forSessionID: session.id)), "the same figures wrote again")
    }

    /// The label keeps one width whatever it reads, so a number that grows does not push the
    /// row past the name budget it was measured with.
    func testTheNumbersKeepTheirWidthAsTheyChange() throws {
        let row = HUDSessionRowView(
            snapshot: measuredSession(processID: 100), now: now, background: .graphite, lampScheme: LampScheme(),
            layout: Self.layout(.both), showsResources: true,
            resourceFigure: ResourceFigure(footprint: 9 * megabyte, cpuLoad: 0.01),
            onFocus: {}, dismissal: .notOffered(until: .distantFuture), onRemove: {})
        let narrow = row.fittingSize.width

        row.refreshResources(ResourceFigure(footprint: 1023 * megabyte, cpuLoad: 9.99))
        row.layoutSubtreeIfNeeded()

        XCTAssertEqual(row.fittingSize.width, narrow, accuracy: 0.5)
    }

    func testSwitchingWatchingAddsAndRemovesThePartWithOneRebuild() throws {
        var resources = WidgetResources()
        let controller = try makeController(resourceStyle: .memory)
        defer { controller.shutdown() }
        controller.resources = { resources }
        let session = measuredSession(processID: 100)
        controller.render(WidgetState(sessions: [session]))
        let off = try XCTUnwrap(controller.currentRow(for: session.id))
        XCTAssertEqual(off.shownResources, [], "watching is off")

        resources.isWatching = true
        controller.resourcesChanged()
        let on = try XCTUnwrap(controller.currentRow(for: session.id))
        XCTAssertFalse(on === off, "the part appears only in a row built with it")
        XCTAssertEqual(on.shownResources, ["–"])

        controller.resourcesChanged()
        XCTAssertTrue(controller.currentRow(for: session.id) === on, "nothing was switched, and the row was rebuilt")

        resources.isWatching = false
        controller.resourcesChanged()
        XCTAssertEqual(try XCTUnwrap(controller.currentRow(for: session.id)).shownResources, [])
    }

    /// A session with no process known — closed, or never matched to one — has nothing a reading
    /// could give, and a dash waiting forever would say otherwise. Nor does a template without
    /// the part draw it.
    func testOnlyARowWithAProcessAndThePartDrawsIt() {
        let template = Self.layout(.memory)
        let noProcess = testSession(lastObservedAt: now)
        var closed = measuredSession(processID: 100)
        closed.phase = .sessionClosed

        XCTAssertFalse(
            HUDRowModel(snapshot: noProcess, now: now, layout: template, watchesResources: true).showsResources)
        XCTAssertFalse(HUDRowModel(snapshot: closed, now: now, layout: template, watchesResources: true).showsResources)
        XCTAssertFalse(
            HUDRowModel(snapshot: measuredSession(processID: 100), now: now, layout: .standard, watchesResources: true)
                .showsResources)
        XCTAssertTrue(
            HUDRowModel(snapshot: measuredSession(processID: 100), now: now, layout: template, watchesResources: true)
                .showsResources)
    }

    func testTheCardNamesTheTotalAndTheHeaviestParts() {
        let claude = SessionResources(
            sessionID: "claude:a",
            parts: [
                .agent: ResourceUsage(footprint: 237 * megabyte),
                .helper("plata-mcp"): ResourceUsage(footprint: 238 * megabyte),
                .commands: ResourceUsage(footprint: 6 * megabyte),
                .orphans: ResourceUsage(footprint: 1 * megabyte),
            ],
            total: ResourceUsage(footprint: 482 * megabyte, resident: 300 * megabyte),
            cpuLoad: 0.25)

        XCTAssertEqual(
            resourceCardLines(.measured(claude, source: .claude)),
            [
                "Memory 482 MB (300 MB in RAM) · CPU 25%",
                "plata-mcp 238 MB · agent 237 MB · commands 6 MB",
                "Subagents run inside the agent and count with it",
            ])
        XCTAssertEqual(
            resourceCardLines(.measured(claude, source: .codex)).count, 2,
            "Codex's subagents are threads of their own, with rows of their own")

        let alone = SessionResources(
            sessionID: "codex:b", parts: [.agent: ResourceUsage(footprint: 200 * megabyte)],
            total: ResourceUsage(footprint: 200 * megabyte, resident: 150 * megabyte))
        XCTAssertEqual(
            resourceCardLines(.measured(alone, source: .codex)), ["Memory 200 MB (150 MB in RAM)"],
            "one part is the total again, and no reading yet has a load")
    }

    /// The decision 5 of the proposal: a thread's commands alone, said as such, rather than a
    /// figure that reads like a light session beside Claude's.
    func testACodexThreadInTheAppSaysItHoldsOnlyItsCommands() {
        let thread = SessionResources(
            sessionID: "codex:t", parts: [.commands: ResourceUsage(footprint: 43 * megabyte)],
            total: ResourceUsage(footprint: 43 * megabyte), cpuLoad: 0.03)

        XCTAssertEqual(
            resourceCardLines(.measured(thread, source: .codex)),
            ["Commands only: memory 43 MB · CPU 3%", "The agent itself runs inside the app"])
        XCTAssertEqual(resourceCardLines(.notRead), ["Memory and CPU: not read yet"])
    }

    func testTheCardSaysNothingUnlessWatchingAndItsSwitchAreOn() {
        let session = measuredSession(processID: 100)
        let reading = report(footprint: 612 * megabyte, cpuTime: 1, sessions: [session], at: now)

        XCTAssertNil(WidgetResources(isWatching: false, showsInCard: true, report: reading).card(for: session))
        XCTAssertNil(WidgetResources(isWatching: true, showsInCard: false, report: reading).card(for: session))
        XCTAssertNil(
            WidgetResources(isWatching: true, showsInCard: true, report: reading)
                .card(for: testSession(lastObservedAt: now)),
            "no process, nothing to read")
        XCTAssertEqual(WidgetResources(isWatching: true, showsInCard: true).card(for: session), .notRead)
        guard case .measured = WidgetResources(isWatching: true, showsInCard: true, report: reading).card(for: session)
        else {
            return XCTFail("a reading that holds the session is its card's")
        }
        let text = hoverCardText(
            for: session, now: now, layout: .standard,
            resources: WidgetResources(isWatching: true, showsInCard: true, report: reading).card(for: session))
        XCTAssertTrue(text.contains("Memory 612 MB"), text)
    }

    /// The card is read now, so it asks for a reading now rather than showing one up to five
    /// seconds old.
    func testOpeningACardAsksForAFreshReading() throws {
        var asked = 0
        let controller = try makeController(resourceStyle: .memory)
        defer { controller.shutdown() }
        controller.resources = { WidgetResources(isWatching: true, showsInCard: true) }
        controller.wantsFreshResources = { asked += 1 }
        let session = measuredSession(processID: 100)
        controller.render(WidgetState(sessions: [session]))
        let row = try XCTUnwrap(controller.currentRow(for: session.id))

        controller.hoverChanged(row, isInside: true)
        controller.showHoverCard(for: session.id)

        XCTAssertEqual(asked, 1)
        XCTAssertTrue(try XCTUnwrap(controller.visibleHoverCardText).contains("Memory and CPU: not read yet"))
    }

    func testThePartStaysSwitchableAndSaysWhyItDrawsNothingWhileWatchingIsOff() {
        let template = Self.layout(.memory)
        XCTAssertEqual(
            RowPartList.note(for: .resources, in: template, watchesResources: false),
            "off: turn on watching in Resources")
        XCTAssertEqual(
            RowPartList.note(for: .resources, in: template, watchesResources: true), "while its process runs")
        XCTAssertEqual(
            RowPartText.layout(template, choosing: 2, for: .resources).resourceStyle, .both)
        XCTAssertEqual(RowPartText.variantIndex(of: .resources, in: template.changing(resourceStyle: .processor)), 1)
    }

    // MARK: - Fixtures

    private static func layout(_ style: RowLayout.ResourceStyle) -> RowLayout {
        RowLayout.standard.changing(parts: RowLayout.standard.parts + [.resources], resourceStyle: style)
    }

    private func measuredSession(processID: Int32) -> SessionSnapshot {
        var session = testSession(title: "меряем", phase: .executing, lastObservedAt: now)
        session.agentProcessID = processID
        return session
    }

    private func report(
        footprint: UInt64,
        cpuTime: TimeInterval,
        sessions: [SessionSnapshot],
        previous: ResourceReport? = nil,
        at date: Date
    ) -> ResourceReport {
        ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: date,
                processes: [
                    SampledProcess(
                        processID: 100, parentProcessID: 1, name: "claude", footprint: footprint, cpuTime: cpuTime)
                ]),
            sessions: sessions,
            previous: previous)
    }

    private func makeController(resourceStyle: RowLayout.ResourceStyle) throws -> HUDPanelController {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let rowLayouts = RowLayoutStore(preferences: preferences)
        rowLayouts.setLayout(Self.layout(resourceStyle))
        let controller = HUDPanelController(
            reach: { _ in .nowhere },
            focus: { _ in .nothingRaised },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: WidgetSettingsStore(preferences: preferences),
            rowLayouts: rowLayouts
        )
        controller.showWindow(nil)
        return controller
    }
}
