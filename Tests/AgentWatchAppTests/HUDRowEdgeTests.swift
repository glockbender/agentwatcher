import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// Where a row's trailing group lands, measured on a list that is really laid out.
///
/// The complaint this answers: the context size and the activity counters sat at the right
/// of the widget in one row and right up against the session name in the next, because a
/// row was only as wide as its own contents and every name is a different length.
@MainActor
final class HUDRowEdgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 9_000)
    /// `HUDSessionListView.horizontalInset` is private; this is the visible width for a
    /// widget of a given width, and the assertions below would fail if it drifted.
    private func visibleWidth(forWidgetWidth width: CGFloat) -> CGFloat {
        width - 2 * (WidgetStyle.standard.contentInset - WidgetStyle.standard.hoverPadding)
    }

    func testEveryRowThatFitsIsAsWideAsTheVisibleArea() {
        let width: CGFloat = 420
        let list = listView(width: width)
        place(list, width: width, height: 200)

        let widths = Set(rows(in: list).map(\.frame.width))

        XCTAssertEqual(widths, [visibleWidth(forWidgetWidth: width)])
    }

    func testTheDismissButtonSitsAtTheRightEdgeRatherThanAfterTheName() {
        let width: CGFloat = 420
        let list = listView(width: width)
        place(list, width: width, height: 200)

        let row = try? XCTUnwrap(rows(in: list).first { $0.snapshot.phase == .sessionClosed })
        let button = try? XCTUnwrap(row?.arrangedSubviews.compactMap { $0 as? NSButton }.last)

        // Against the trailing edge, inside the row's own padding. Compared on the
        // alignment rect, not the frame: a bezelled button's frame is wider than the box
        // Auto Layout positions, so a frame comparison is off by the bezel's inset.
        let alignment = button.map { $0.alignmentRect(forFrame: $0.frame) }
        XCTAssertEqual(
            alignment?.maxX ?? 0,
            (row?.frame.width ?? 0) - WidgetStyle.standard.hoverPadding,
            accuracy: 0.5
        )
    }

    /// A row that cannot shrink to fit keeps its own width and is reached by scrolling. The
    /// rows that do fit must not be dragged along with it — measured at 190 pt, that used to
    /// push their dismiss button to 180…204 with only 178 visible.
    func testARowTooWideToFitDoesNotWidenTheRowsThatFit() {
        let width: CGFloat = 190
        let list = listView(width: width)
        place(list, width: width, height: 200)

        let visible = visibleWidth(forWidgetWidth: width)
        let busy = rows(in: list).first { !$0.snapshot.activities.isEmpty }
        let closed = rows(in: list).first { $0.snapshot.phase == .sessionClosed }

        XCTAssertGreaterThan(busy?.frame.width ?? 0, visible, "this row really cannot fit")
        XCTAssertEqual(closed?.frame.width ?? 0, visible, accuracy: 0.5)

        let button = closed?.arrangedSubviews.compactMap { $0 as? NSButton }.last
        let alignment = button.map { $0.alignmentRect(forFrame: $0.frame) }
        XCTAssertLessThanOrEqual(alignment?.maxX ?? .infinity, visible)
    }

    /// Building a list measures every row, and measuring a view lays it out. A layout pass
    /// started inside another one is what hung the widget once, so the measurement must not
    /// reach anything already on screen — the widget rebuilds its list from
    /// `windowDidResize`, which is close enough to a layout pass to be worth pinning down.
    func testBuildingAListDoesNotLayOutWhatIsAlreadyOnScreen() {
        let counter = CountingView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = counter
        counter.layoutSubtreeIfNeeded()

        counter.layoutPasses = 0
        _ = listView(width: 420)

        XCTAssertEqual(counter.layoutPasses, 0)
    }

    private func rows(in list: HUDSessionListView) -> [HUDSessionRowView] {
        allSubviews(of: list).compactMap { $0 as? HUDSessionRowView }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func listView(width: CGFloat) -> HUDSessionListView {
        var busy = snapshot(index: 0, title: "AGENTS.md интеграция в CLAUDE.md", phase: .executing)
        busy.activities = [
            SessionActivity(id: "a1", kind: .subagent, startedAt: now, outlivesTurn: true),
            SessionActivity(id: "a2", kind: .shell, startedAt: now),
        ]
        busy.contextTelemetry = SessionContextTelemetry(totalInputTokens: 333_000)

        return HUDSessionListView(
            models: rowModels(
                [busy, snapshot(index: 1, title: "Старая сессия", phase: .sessionClosed)], now: now),
            usageLimits: [],
            now: now,
            availableWidth: width,
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            restoredScrollOffset: nil,
            onScroll: { _ in }
        )
    }

    private func snapshot(index: Int, title: String, phase: SessionPhase) -> SessionSnapshot {
        testSession(
            index: index,
            title: title,
            mode: .standard,
            phase: phase,
            lastObservedAt: now.addingTimeInterval(-8)
        )
    }

    private func place(_ list: HUDSessionListView, width: CGFloat, height: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = list
        window.setContentSize(NSSize(width: width, height: height))
        list.layoutSubtreeIfNeeded()
    }
}

private final class CountingView: NSView {
    var layoutPasses = 0

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}
