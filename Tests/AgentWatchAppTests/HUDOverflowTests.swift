import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The `▾ N more` counter, measured on a list view that is really laid out and really
/// resized. Feeding synthetic rectangles to the counting function cannot catch a count
/// taken against a scroll view that has not finished moving.
@MainActor
final class HUDOverflowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 7_000)

    func testNothingIsReportedHiddenWhenEveryRowFits() {
        let list = listView(sessionCount: 3)
        place(list, height: 300)

        XCTAssertEqual(list.hiddenSessionCount, 0)
    }

    func testRowsPastTheBottomAreReported() {
        let list = listView(sessionCount: 8)
        place(list, height: 60)

        XCTAssertGreaterThan(list.hiddenSessionCount, 0)
    }

    /// The complaint this answers: the counter stood there announcing sessions while the list
    /// was scrolled all the way down and every one of them had been read. It counted the rows
    /// scrolled past above as well as the ones still below — under a `▾` that points down.
    func testTheCounterGoesAwayAtTheBottomOfTheList() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 80)
        XCTAssertGreaterThan(list.hiddenSessionCount, 0, "this size really does cut rows off")
        let badge = try XCTUnwrap(firstBadge(in: list))

        try scrollToBottom(list)

        XCTAssertEqual(list.hiddenSessionCount, 0, "nothing is below the view any more")
        XCTAssertTrue(badge.isHidden)
    }

    /// One row down is one row fewer still to come. The count used to stand still here: the
    /// row that left the top was counted the moment the row that arrived at the bottom
    /// stopped being.
    func testScrollingDownTakesOffTheRowItReveals() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 80)
        let atTheTop = list.hiddenSessionCount
        XCTAssertGreaterThan(atTheTop, 1, "this size really does cut rows off")

        try scroll(list, by: HUDSessionRowView.rowHeight + HUDSessionListView.rowSpacing)

        XCTAssertEqual(list.hiddenSessionCount, atTheTop - 1)
    }

    /// The counter used to sit under the list and take a strip of height from it, so it was
    /// partly the cause of what it reported: while it was there the widget showed one row
    /// fewer. As a badge over the list it costs the rows nothing.
    func testTheCounterTakesNoHeightFromTheList() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 60)
        XCTAssertGreaterThan(list.hiddenSessionCount, 0, "this size really does cut rows off")

        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        let badge = try XCTUnwrap(firstBadge(in: list))
        XCTAssertEqual(
            scrollView.frame.maxY,
            list.bounds.maxY - HUDSessionListView.verticalPadding,
            accuracy: 0.5,
            "the list reaches the bottom of the widget whether or not the counter is showing"
        )
        XCTAssertFalse(badge.isHidden)
        XCTAssertTrue(
            badge.frame.intersects(scrollView.frame),
            "the badge is over the list, which is the only way it can cost it nothing"
        )
    }

    /// Wherever it sits the badge hides part of a row, so it sits in the margin the rows
    /// already leave clear — past their right edge and below their last line — rather than in
    /// line with them. The rows keep their own inset; only the badge goes into the border.
    func testTheCounterSitsInTheMarginTheRowsLeaveClear() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 80)
        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        let badge = try XCTUnwrap(firstBadge(in: list))
        let frame = badge.convert(badge.bounds, to: list)
        let rows = scrollView.convert(scrollView.bounds, to: list)

        XCTAssertGreaterThan(frame.maxX, rows.maxX, "past the right edge the rows stop at")
        XCTAssertLessThan(frame.minY, rows.minY, "and below the line they stop at")
        XCTAssertTrue(list.bounds.contains(frame), "without leaving the widget")
    }

    /// The badge lands where a row keeps its `×`, and that button is the only way to clear a
    /// session that has stopped. Covering it whole takes the gesture away; this leaves most of
    /// it showing.
    func testTheCounterLeavesTheDismissButtonShowing() throws {
        let list = listView(sessionCount: 8, phase: .sessionClosed)
        place(list, height: 80)
        let badge = try XCTUnwrap(firstBadge(in: list))
        XCTAssertFalse(badge.isHidden, "this size really does cut rows off")

        let button = try XCTUnwrap(lowestFullyVisibleDismissButton(in: list))
        let covered = badge.convert(badge.bounds, to: list).intersection(button)

        XCTAssertGreaterThan(
            button.height - covered.height,
            button.height / 2,
            "over half the button has to stay in sight to be aimed at"
        )
    }

    /// The badge drops into the border below the list. Where there is an account usage block
    /// down there the border is all it may take: the divider and the figures under it are not
    /// a row, and nothing announces them.
    func testTheCounterStaysClearOfTheUsageBlock() throws {
        let list = listView(
            sessionCount: 8,
            usageLimits: [AgentUsageLimits(source: .claude, fiveHour: .init(usedPercentage: 17), observedAt: now)]
        )
        place(list, height: 120)
        let badge = try XCTUnwrap(firstBadge(in: list))
        XCTAssertFalse(badge.isHidden, "this size really does cut rows off")
        let divider = try XCTUnwrap(allSubviews(of: list).compactMap { $0 as? NSBox }.first)

        XCTAssertGreaterThanOrEqual(
            badge.convert(badge.bounds, to: list).minY,
            divider.convert(divider.bounds, to: list).maxY
        )
    }

    /// It lies over a row a person can hover, dismiss and scroll. A badge that took those
    /// presses would cost more than it tells.
    func testTheCounterTakesNoClicks() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 60)
        let badge = try XCTUnwrap(firstBadge(in: list))

        XCTAssertNil(badge.hitTest(NSPoint(x: badge.bounds.midX, y: badge.bounds.midY)))
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func firstBadge(in view: NSView) -> HUDOverflowBadge? {
        if let badge = view as? HUDOverflowBadge {
            return badge
        }
        return view.subviews.lazy.compactMap { self.firstBadge(in: $0) }.first
    }

    /// Moves the list the way a wheel does, and lets the count settle afterwards.
    private func scroll(_ list: HUDSessionListView, by delta: CGFloat) throws {
        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        // The document view is flipped, so a larger `y` is further down the list.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.documentVisibleRect.minY + delta))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(list)
    }

    private func scrollToBottom(_ list: HUDSessionListView) throws {
        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        let document = try XCTUnwrap(scrollView.documentView)
        try scroll(list, by: document.bounds.height - scrollView.documentVisibleRect.maxY)
    }

    /// The `×` of the lowest row that is wholly in view, in the list's own coordinates.
    /// That is the row the badge lands on, and the button it can take away.
    private func lowestFullyVisibleDismissButton(in list: HUDSessionListView) throws -> NSRect? {
        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        let visible = scrollView.documentVisibleRect
        guard
            let row = list.rows.last(where: { visible.contains($0.frame) }),
            let button = allSubviews(of: row).compactMap({ $0 as? RowDismissButton }).first
        else {
            return nil
        }
        return button.convert(button.bounds, to: list)
    }

    /// The complaint this answers: after a few resizes the widget claimed sessions were
    /// hidden while all of them were visible.
    func testGrowingTheWidgetBackClearsTheCount() {
        let list = listView(sessionCount: 4)
        place(list, height: 300)
        place(list, height: 50)
        XCTAssertGreaterThan(list.hiddenSessionCount, 0, "this size really does cut rows off")

        place(list, height: 300)

        XCTAssertEqual(list.hiddenSessionCount, 0, "every row fits again, so nothing is hidden")
    }

    /// Rows the diff inserts and removes have to move the counter the way a rebuild did. The
    /// count is taken from real frames after layout, and a row `apply` has just inserted has
    /// none until the pass that follows.
    func testTheCounterFollowsRowsTheDiffAddsAndRemoves() {
        let list = listView(sessionCount: 3)
        place(list, height: 300)
        XCTAssertEqual(list.hiddenSessionCount, 0)

        list.apply(models: rowModels((0..<30).map { session(index: $0) }, now: now), now: now)
        list.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(list.hiddenSessionCount, 0, "thirty rows do not fit in 300 points")

        list.apply(models: rowModels((0..<3).map { session(index: $0) }, now: now), now: now)
        list.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.hiddenSessionCount, 0, "every row fits again, so nothing is hidden")
    }

    /// Widening changes no vertical fact, so it must not change the count — and the rows
    /// here are deliberately far wider than the narrow widget, which is the situation that
    /// used to make the counter claim sessions were missing while all of them were visible.
    func testARowWiderThanTheWidgetIsNotCountedAsHidden() {
        let list = listView(sessionCount: 4, title: String(repeating: "очень длинное имя ", count: 12))
        place(list, width: 240, height: 300)
        let narrow = list.hiddenSessionCount

        place(list, width: 900, height: 300)

        XCTAssertEqual(narrow, 0, "every row fits vertically, however far it runs off the side")
        XCTAssertEqual(list.hiddenSessionCount, narrow, "width is not a vertical fact")
    }

    /// A tooltip needs about a second of hovering over a view that is still there. The list
    /// used to be rebuilt from scratch on every tick, so the view under the pointer was
    /// destroyed before any tooltip could appear.
    func testATickAdvancesTheTimersWithoutReplacingASingleRow() throws {
        let list = listView(sessionCount: 3)
        place(list, height: 300)
        let before = rows(in: list)
        let firstTimer = try XCTUnwrap(timerText(in: try XCTUnwrap(before.first)))

        list.refreshTimers(now: now.addingTimeInterval(125))

        let after = rows(in: list)
        XCTAssertEqual(after.count, before.count)
        for (old, new) in zip(before, after) {
            XCTAssertTrue(old === new, "the row under the pointer has to survive a tick")
        }
        XCTAssertEqual(firstTimer, "0s")
        XCTAssertEqual(timerText(in: try XCTUnwrap(after.first)), "2m")
    }

    /// A tick that reads the same must write nothing: writing marks the label for redraw,
    /// and a redraw here re-blurs the translucent panel behind it. Measured, 96 of 2400
    /// ticks over five minutes of eight rows read differently.
    func testATickThatReadsTheSameWritesNothing() {
        let list = listView(sessionCount: 3)
        place(list, height: 200)
        // A minute in, the timers read in whole minutes and stay put for the next 59 seconds.
        list.refreshTimers(now: now.addingTimeInterval(90))

        XCTAssertEqual(list.refreshTimers(now: now.addingTimeInterval(91)), 0)
        XCTAssertEqual(list.refreshTimers(now: now.addingTimeInterval(100)), 0)
    }

    func testATickThatReadsDifferentlyWritesEveryRowThatChanged() {
        let list = listView(sessionCount: 3)
        place(list, height: 200)
        list.refreshTimers(now: now.addingTimeInterval(1))

        // Past the minute mark the timers switch from seconds to minutes.
        XCTAssertEqual(list.refreshTimers(now: now.addingTimeInterval(61)), 3)
    }

    private func rows(in list: HUDSessionListView) -> [HUDSessionRowView] {
        allSubviews(of: list).compactMap { $0 as? HUDSessionRowView }
    }

    private func timerText(in row: HUDSessionRowView) -> String? {
        row.arrangedSubviews.compactMap { $0 as? NSTextField }.first?.stringValue
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    /// A legacy scroller takes 15 measured points out of the clip view, and the name budget
    /// is computed against the full width — so a widget on a system set to "show scroll bars
    /// always" would size names for room they do not have.
    func testTheListKeepsItsFullWidthWhateverTheSystemScrollerStyleIs() throws {
        let list = listView(sessionCount: 6)
        place(list, width: 300, height: 80)

        let scrollView = try XCTUnwrap(allSubviews(of: list).compactMap { $0 as? NSScrollView }.first)

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.contentView.frame.width, scrollView.frame.width, accuracy: 0.5)
    }

    /// The window height and the content it frames come from one place now. This checks that
    /// the number the window is sized to is the height a real list of that many rows takes.
    func testTheSelfSizedHeightMatchesWhatTheListActuallyLaysOut() {
        for count in [1, 2, 4, 8] {
            let list = listView(sessionCount: count)
            let expected = HUDSessionListView.selfSizedHeight(
                sessionCount: count,
                usageLimits: [],
                background: .graphite
            )
            place(list, height: expected)

            let rows = allSubviews(of: list).compactMap { $0 as? HUDSessionRowView }
            XCTAssertEqual(rows.count, count)
            XCTAssertEqual(
                hiddenRowCount(
                    rowFrames: rows.map(\.frame),
                    visibleRect: try! XCTUnwrap(
                        allSubviews(of: list).compactMap { $0 as? NSScrollView }.first
                    ).documentVisibleRect
                ),
                0,
                "\(count) rows must all fit in the height the widget was sized to"
            )
        }
    }

    /// The usage block is part of that height, so a widget showing account limits has to be
    /// taller than the same list without them — by the block plus its divider, not by a
    /// guess at a label's height.
    func testTheUsageBlockAddsItsOwnMeasuredHeight() {
        let bare = HUDSessionListView.selfSizedHeight(sessionCount: 3, usageLimits: [], background: .graphite)
        let withUsage = HUDSessionListView.selfSizedHeight(
            sessionCount: 3,
            usageLimits: [AgentUsageLimits(source: .claude, fiveHour: .init(usedPercentage: 17), observedAt: now)],
            background: .graphite
        )

        XCTAssertGreaterThan(withUsage - bare, 15, "a row of text plus a separator and its gaps")
        XCTAssertLessThan(withUsage - bare, 40, "and not much more than that")
    }

    func testAnEmptyListIsGivenNoHeightOfItsOwn() {
        XCTAssertEqual(
            HUDSessionListView.selfSizedHeight(sessionCount: 0, usageLimits: [], background: .graphite),
            0,
            "the empty state has its own height and this must not compete with it"
        )
    }

    /// Taking the count used to change a constraint, and the count is taken inside AppKit's
    /// own layout pass — so the layout engine was asked to run while it was already running.
    /// Captured in the running app as `_layoutSubtreeWithOldSize:` recursing on itself until
    /// the widget stopped answering the pointer.
    ///
    /// This drives the count up and down repeatedly and counts the layout passes it costs.
    func testChangingTheCountDoesNotSetOffAnotherLayoutPass() {
        let list = CountingListView(
            models: rowModels((0..<6).map { session(index: $0) }, now: now),
            usageLimits: [],
            now: now,
            availableWidth: 300,
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            restoredScrollOffset: nil,
            onScroll: { _ in }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = list
        list.layoutSubtreeIfNeeded()

        // Heights chosen so the counter has to change on every step: all six rows fit at
        // 200, none at 40.
        list.layoutPasses = 0
        for height in [40.0, 200.0, 40.0, 200.0, 60.0, 200.0] {
            window.setContentSize(NSSize(width: 300, height: height))
            list.layoutSubtreeIfNeeded()
        }

        XCTAssertGreaterThan(list.hiddenSessionCount, -1)
        XCTAssertLessThanOrEqual(
            list.layoutPasses,
            12,
            "six size changes, at most two passes each — more means a pass is causing the next"
        )
    }

    private func listView(
        sessionCount: Int,
        title: String? = nil,
        phase: SessionPhase = .executing,
        usageLimits: [AgentUsageLimits] = []
    ) -> HUDSessionListView {
        HUDSessionListView(
            models: rowModels(
                (0..<sessionCount).map { session(index: $0, title: title, phase: phase) },
                now: now
            ),
            usageLimits: usageLimits,
            now: now,
            availableWidth: 400,
            focus: { _ in },
            remove: { _ in },
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            restoredScrollOffset: nil,
            onScroll: { _ in }
        )
    }

    private func place(_ list: HUDSessionListView, width: CGFloat = 400, height: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = list
        window.setContentSize(NSSize(width: width, height: height))
        settle(list)
    }

    /// Two passes, because the counter's text is written during the first one: a label given
    /// a new string is only as wide as that string on the pass that follows. AppKit runs that
    /// second pass by itself before anything is drawn; a test has to ask for it.
    private func settle(_ list: HUDSessionListView) {
        list.layoutSubtreeIfNeeded()
        list.layoutSubtreeIfNeeded()
    }

    private func session(index: Int, title: String? = nil, phase: SessionPhase = .executing) -> SessionSnapshot {
        testSession(index: index, title: title ?? "Session \(index)", phase: phase, lastObservedAt: now)
    }
}

/// Counts how many times AppKit lays this view out.
@MainActor
private final class CountingListView: HUDSessionListView {
    var layoutPasses = 0

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}
