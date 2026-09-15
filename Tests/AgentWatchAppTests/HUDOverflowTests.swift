import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The two `+N` counters, measured on a list view that is really laid out and really
/// resized. Feeding synthetic rectangles to the counting function cannot catch a count
/// taken against a scroll view that has not finished moving.
@MainActor
final class HUDOverflowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 7_000)

    func testNothingIsReportedHiddenWhenEveryRowFits() {
        let list = listView(sessionCount: 3)
        place(list, height: 300)

        XCTAssertEqual(list.hiddenSessions, .none)
        XCTAssertTrue(list.overflowBadgeAbove.isHidden)
        XCTAssertTrue(list.overflowBadgeBelow.isHidden)
    }

    func testRowsPastTheBottomAreReported() {
        let list = listView(sessionCount: 8)
        place(list, height: 60)

        XCTAssertGreaterThan(list.hiddenSessions.below, 0)
        XCTAssertEqual(list.hiddenSessions.above, 0, "nothing has been scrolled past yet")
    }

    /// Each counter says how many rows lie that way, in as few characters as the fact needs.
    /// The arrow it used to carry said the same thing as the corner it sits in.
    func testEachCounterReadsAsAPlainCount() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 80)
        let below = list.hiddenSessions.below
        XCTAssertGreaterThan(below, 0, "this size really does cut rows off")
        XCTAssertEqual(list.overflowBadgeBelow.label.stringValue, "+\(below)")

        try scrollToBottom(list)

        XCTAssertEqual(list.overflowBadgeAbove.label.stringValue, "+\(list.hiddenSessions.above)")
    }

    /// The complaint the two counters answer: one number counting both ways stood at the
    /// bottom of the list announcing sessions that had already been read. Each corner now
    /// reports only what lies that way, so the bottom one goes quiet exactly when there is
    /// nothing below — and the top one takes over.
    func testAtTheBottomOfTheListOnlyTheCounterAboveIsLeft() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 80)
        XCTAssertGreaterThan(list.hiddenSessions.below, 0, "this size really does cut rows off")
        XCTAssertTrue(list.overflowBadgeAbove.isHidden, "nothing is above the view at the top")

        try scrollToBottom(list)

        XCTAssertEqual(list.hiddenSessions.below, 0, "nothing is below the view any more")
        XCTAssertTrue(list.overflowBadgeBelow.isHidden)
        XCTAssertGreaterThan(list.hiddenSessions.above, 0, "but the rows scrolled past are")
        XCTAssertFalse(list.overflowBadgeAbove.isHidden)
    }

    /// One row down is one row fewer still to come, and one more behind. The count used to
    /// stand still here: the row that left the top was counted the moment the row that
    /// arrived at the bottom stopped being.
    func testScrollingDownMovesARowFromOneCounterToTheOther() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 80)
        let atTheTop = list.hiddenSessions
        XCTAssertGreaterThan(atTheTop.below, 1, "this size really does cut rows off")

        try scroll(list, by: WidgetStyle.standard.rowHeight + WidgetStyle.standard.rowSpacing)

        XCTAssertEqual(list.hiddenSessions.below, atTheTop.below - 1)
        XCTAssertEqual(list.hiddenSessions.above, atTheTop.above + 1)
    }

    /// The complaint this answers, measured on a real list rather than on rectangles: dragging
    /// the widget three points shorter clipped the last row by three points of its nineteen,
    /// and the counter stood up to announce a session that was in fact almost wholly on
    /// screen. Eight points short is over a third of the row, and then it is right to.
    func testAWidgetShortByAFewPointsDoesNotAnnounceTheRowItClips() {
        let fits = HUDSessionListView.selfSizedHeight(sessionCount: 4, usageLimits: [], background: .graphite)

        let barely = listView(sessionCount: 4)
        place(barely, height: fits - 3)
        XCTAssertEqual(barely.hiddenSessions, .none, "the last row is clipped by 3 points of 19 and still readable")
        XCTAssertTrue(barely.overflowBadgeBelow.isHidden)

        let properly = listView(sessionCount: 4)
        place(properly, height: fits - 8)
        XCTAssertEqual(properly.hiddenSessions.below, 1, "8 points of 19 is past the third and worth saying")
        XCTAssertFalse(properly.overflowBadgeBelow.isHidden)
    }

    /// The two features have to hold together: the badge answers for what is cut off, and the
    /// scale changes how tall a row is. The allowance is a fraction of the row's own frame, so
    /// it follows the scale without being told — 3.6 points at half size, 11.4 at double.
    /// Stated at every size on offer, because a fraction swapped for a count of points would
    /// pass at 100% and be wrong everywhere else.
    func testTheAllowanceFollowsTheSizeThePersonChose() {
        for scale in WidgetSettingsStore.offeredScales {
            let style = WidgetStyle(scale: scale)
            let fits = HUDSessionListView.selfSizedHeight(
                sessionCount: 4, usageLimits: [], background: .graphite, style: style
            )
            let allowance = style.rowHeight * hiddenRowFraction
            let percent = Int(scale * 100)

            let under = listView(sessionCount: 8, style: style)
            place(under, height: fits - (allowance - 1))
            let over = listView(sessionCount: 8, style: style)
            place(over, height: fits - (allowance + 1))

            XCTAssertEqual(
                over.hiddenSessions.below,
                under.hiddenSessions.below + 1,
                "at \(percent)% the row clipped past the allowance counts and the one under it does not"
            )
        }
    }

    /// A widget at double size holds fewer rows in the same height, so the two badges come
    /// closest to each other at the largest size — and they must not meet, because one
    /// capsule sitting on another reads as neither.
    func testTheTwoCountersNeverMeetAtAnySize() throws {
        for scale in WidgetSettingsStore.offeredScales {
            let style = WidgetStyle(scale: scale)
            let fits = HUDSessionListView.selfSizedHeight(
                sessionCount: 8, usageLimits: [], background: .graphite, style: style
            )
            let list = listView(sessionCount: 8, style: style)
            place(list, height: fits * 0.6)
            try scroll(list, by: style.rowHeight + style.rowSpacing)
            let percent = Int(scale * 100)

            XCTAssertGreaterThan(list.hiddenSessions.above, 0, "at \(percent)% rows really are above")
            XCTAssertGreaterThan(list.hiddenSessions.below, 0, "at \(percent)% rows really are below")
            XCTAssertFalse(
                list.overflowBadgeAbove.convert(list.overflowBadgeAbove.bounds, to: list)
                    .intersects(list.overflowBadgeBelow.convert(list.overflowBadgeBelow.bounds, to: list)),
                "at \(percent)% the two capsules overlap"
            )
        }
    }

    /// The counter used to sit under the list and take a strip of height from it, so it was
    /// partly the cause of what it reported: while it was there the widget showed one row
    /// fewer. As a badge over the list it costs the rows nothing.
    func testTheCounterTakesNoHeightFromTheList() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 60)
        XCTAssertGreaterThan(list.hiddenSessions.below, 0, "this size really does cut rows off")

        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        let badge = list.overflowBadgeBelow
        XCTAssertEqual(
            scrollView.frame.maxY,
            list.bounds.maxY - WidgetStyle.standard.listVerticalPadding,
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
        let badge = list.overflowBadgeBelow
        let frame = badge.convert(badge.bounds, to: list)
        let rows = scrollView.convert(scrollView.bounds, to: list)

        XCTAssertGreaterThan(frame.maxX, rows.maxX, "past the right edge the rows stop at")
        XCTAssertLessThan(frame.minY, rows.minY, "and below the line they stop at")
        XCTAssertTrue(list.bounds.contains(frame), "without leaving the widget")
    }

    /// The same margin at the other end. The list view is not flipped, so "above the rows"
    /// is the larger `y` here.
    func testTheCounterAboveSitsInTheSameMargin() throws {
        let list = listView(sessionCount: 8)
        place(list, height: 80)
        try scrollToBottom(list)
        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        let badge = list.overflowBadgeAbove
        XCTAssertFalse(badge.isHidden, "the list really is scrolled past some rows")
        let frame = badge.convert(badge.bounds, to: list)
        let rows = scrollView.convert(scrollView.bounds, to: list)

        XCTAssertGreaterThan(frame.maxX, rows.maxX, "past the right edge the rows stop at")
        XCTAssertGreaterThan(frame.maxY, rows.maxY, "and above the line they start at")
        XCTAssertTrue(list.bounds.contains(frame), "without leaving the widget")
    }

    /// Both counters can stand at once — a list scrolled to the middle has rows either way —
    /// and neither may land on the other.
    func testBothCountersCanStandAtOnceWithoutMeeting() throws {
        let list = listView(sessionCount: 20)
        place(list, height: 120)
        try scroll(list, by: 3 * (WidgetStyle.standard.rowHeight + WidgetStyle.standard.rowSpacing))

        XCTAssertGreaterThan(list.hiddenSessions.above, 0)
        XCTAssertGreaterThan(list.hiddenSessions.below, 0)
        XCTAssertFalse(list.overflowBadgeAbove.isHidden)
        XCTAssertFalse(list.overflowBadgeBelow.isHidden)
        XCTAssertFalse(
            list.overflowBadgeAbove.convert(list.overflowBadgeAbove.bounds, to: list)
                .intersects(list.overflowBadgeBelow.convert(list.overflowBadgeBelow.bounds, to: list))
        )
    }

    /// A badge lands where a row keeps its `×`, and that button is the only way to clear a
    /// session that has stopped. What has to survive is the mark, not the box around it: the
    /// bezel is 22 points at full size and the `×` drawn inside it is 16, so a badge can take a
    /// third of the bezel and none of the mark. Counted in ink on a bitmap, because the mark
    /// is the button's title and has no frame of its own to ask.
    ///
    /// The bar is in two parts, and both halves are measurements rather than preferences. From
    /// full size up at least half the mark stays showing under either badge: 56, 57, 50, 55
    /// and 62 per cent at the five sizes from 100 to 200, so the bar is "not less than half"
    /// and 150 % is the size that sits exactly on it. Below full size the badge keeps
    /// floors the row does not — `NSTextField` will not let the label shrink past its text —
    /// so at 75 % 46 % of the mark is left and at half size 25 %. Deliberately left there: the
    /// badge takes no clicks, so the `×` under it is still pressed, and what a small widget
    /// loses is a glance, not a gesture.
    func testEitherCounterLeavesTheDismissMarkShowing() throws {
        for scale in WidgetSettingsStore.offeredScales {
            let style = WidgetStyle(scale: scale)
            let fits = HUDSessionListView.selfSizedHeight(
                sessionCount: 8, usageLimits: [], background: .graphite, style: style
            )
            let list = listView(sessionCount: 8, phase: .sessionClosed, style: style)
            place(list, height: fits * 0.6)
            try scroll(list, by: style.rowHeight + style.rowSpacing)
            let percent = Int(scale * 100)
            let whole = try wholeRowsInView(of: list)

            for (badge, row) in [
                (list.overflowBadgeAbove, whole.first),
                (list.overflowBadgeBelow, whole.last),
            ] {
                XCTAssertFalse(badge.isHidden, "at \(percent)% this size really does cut rows off")
                let mark = try XCTUnwrap(dismissMarkInk(of: try XCTUnwrap(row), in: list))
                let left = mark.height - badge.convert(badge.bounds, to: list).intersection(mark).height

                XCTAssertGreaterThan(left, 0, "at \(percent)% the mark is wholly covered")
                if scale >= 1 {
                    XCTAssertGreaterThanOrEqual(
                        left,
                        mark.height / 2,
                        "at \(percent)% half the mark has to stay in sight"
                    )
                }
            }
        }
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
        let badge = list.overflowBadgeBelow
        XCTAssertFalse(badge.isHidden, "this size really does cut rows off")
        let divider = try XCTUnwrap(allSubviews(of: list).compactMap { $0 as? NSBox }.first)

        XCTAssertGreaterThanOrEqual(
            badge.convert(badge.bounds, to: list).minY,
            divider.convert(divider.bounds, to: list).maxY
        )
    }

    /// It lies over a row a person can hover, dismiss and scroll. A badge that took those
    /// presses would cost more than it tells.
    func testNeitherCounterTakesClicks() {
        let list = listView(sessionCount: 8)
        place(list, height: 60)

        for badge in [list.overflowBadgeAbove, list.overflowBadgeBelow] {
            XCTAssertNil(badge.hitTest(NSPoint(x: badge.bounds.midX, y: badge.bounds.midY)))
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
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

    /// Every row that is wholly in view, top to bottom. The first and the last of them are the
    /// rows the two badges land on.
    private func wholeRowsInView(of list: HUDSessionListView) throws -> [HUDSessionRowView] {
        let scrollView = try XCTUnwrap(firstScrollView(in: list))
        let visible = scrollView.documentVisibleRect
        return list.rows.filter { visible.contains($0.frame) }
    }

    /// The box the row's `×` mark actually occupies, in the list's own coordinates.
    ///
    /// Counted in ink rather than asked of a view: with a bezel the mark is the button's
    /// title, which has no frame to read, and the bezel is half again as tall as the mark
    /// inside it. The button is drawn on its own, so no badge can erase the ink being
    /// measured.
    private func dismissMarkInk(of row: HUDSessionRowView, in list: HUDSessionListView) throws -> NSRect? {
        let button = try XCTUnwrap(allSubviews(of: row).compactMap { $0 as? RowDismissButton }.first)
        let bounds = button.bounds
        guard let rep = button.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        button.cacheDisplay(in: bounds, to: rep)

        // The corner is the button's own background; ink is anything far enough from it.
        guard let corner = rep.colorAt(x: 0, y: 0) else { return nil }
        var top: Int?
        var bottom: Int?
        for y in 0..<rep.pixelsHigh
        where (0..<rep.pixelsWide).contains(where: { x in
            guard let pixel = rep.colorAt(x: x, y: y) else { return false }
            return colourDistance(pixel, corner) > 0.18
        }) {
            if top == nil { top = y }
            bottom = y
        }
        guard let top, let bottom else { return nil }

        // The bitmap counts down from the top; the button's own coordinates count up.
        let perPixel = bounds.height / CGFloat(rep.pixelsHigh)
        return button.convert(
            NSRect(
                x: bounds.minX,
                y: bounds.maxY - CGFloat(bottom + 1) * perPixel,
                width: bounds.width,
                height: CGFloat(bottom - top + 1) * perPixel
            ),
            to: list
        )
    }

    private func colourDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard
            let left = a.usingColorSpace(.deviceRGB),
            let right = b.usingColorSpace(.deviceRGB)
        else { return 0 }
        return abs(left.redComponent - right.redComponent)
            + abs(left.greenComponent - right.greenComponent)
            + abs(left.blueComponent - right.blueComponent)
    }

    /// The complaint this answers: after a few resizes the widget claimed sessions were
    /// hidden while all of them were visible.
    func testGrowingTheWidgetBackClearsTheCount() {
        let list = listView(sessionCount: 4)
        place(list, height: 300)
        place(list, height: 50)
        XCTAssertGreaterThan(list.hiddenSessions.below, 0, "this size really does cut rows off")

        place(list, height: 300)

        XCTAssertEqual(list.hiddenSessions, .none, "every row fits again, so nothing is hidden")
    }

    /// Rows the diff inserts and removes have to move the counter the way a rebuild did. The
    /// count is taken from real frames after layout, and a row `apply` has just inserted has
    /// none until the pass that follows.
    func testTheCounterFollowsRowsTheDiffAddsAndRemoves() {
        let list = listView(sessionCount: 3)
        place(list, height: 300)
        XCTAssertEqual(list.hiddenSessions, .none)

        list.apply(models: rowModels((0..<30).map { session(index: $0) }, now: now), now: now)
        list.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(list.hiddenSessions.below, 0, "thirty rows do not fit in 300 points")

        list.apply(models: rowModels((0..<3).map { session(index: $0) }, now: now), now: now)
        list.layoutSubtreeIfNeeded()
        XCTAssertEqual(list.hiddenSessions, .none, "every row fits again, so nothing is hidden")
    }

    /// Widening changes no vertical fact, so it must not change the count — and the rows
    /// here are deliberately far wider than the narrow widget, which is the situation that
    /// used to make the counter claim sessions were missing while all of them were visible.
    func testARowWiderThanTheWidgetIsNotCountedAsHidden() {
        let list = listView(sessionCount: 4, title: String(repeating: "очень длинное имя ", count: 12))
        place(list, width: 240, height: 300)
        let narrow = list.hiddenSessions

        place(list, width: 900, height: 300)

        XCTAssertEqual(narrow, .none, "every row fits vertically, however far it runs off the side")
        XCTAssertEqual(list.hiddenSessions, narrow, "width is not a vertical fact")
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
                hiddenRows(
                    rowFrames: rows.map(\.frame),
                    visibleRect: try! XCTUnwrap(
                        allSubviews(of: list).compactMap { $0 as? NSScrollView }.first
                    ).documentVisibleRect
                ),
                .none,
                "\(count) rows must all fit in the height the widget was sized to"
            )
        }
    }

    /// And it matches at every size the widget can be drawn at. The height the window is
    /// given and the height its rows take are computed from the same style, so a scale that
    /// reached one of them and not the other shows up as rows cut off by the widget's own
    /// bottom edge.
    func testTheSelfSizedHeightMatchesAtEverySizeOnOffer() throws {
        for scale in WidgetSettingsStore.offeredScales {
            let style = WidgetStyle(scale: scale)
            let list = listView(sessionCount: 4, style: style)
            let expected = HUDSessionListView.selfSizedHeight(
                sessionCount: 4,
                usageLimits: [],
                background: .graphite,
                style: style
            )
            place(list, height: expected)

            let rows = allSubviews(of: list).compactMap { $0 as? HUDSessionRowView }
            let scrollView = try XCTUnwrap(allSubviews(of: list).compactMap { $0 as? NSScrollView }.first)
            XCTAssertEqual(
                hiddenRows(rowFrames: rows.map(\.frame), visibleRect: scrollView.documentVisibleRect),
                .none,
                "at \(Int(scale * 100))% the rows do not fit the height the widget was sized to"
            )
        }
    }

    /// A larger widget needs more room for the same sessions. Stated on its own because the
    /// test above would still pass if the height stopped following the scale and every row
    /// stopped growing with it too.
    func testALargerWidgetAsksForMoreHeight() {
        let small = HUDSessionListView.selfSizedHeight(
            sessionCount: 4, usageLimits: [], background: .graphite, style: .standard)
        let large = HUDSessionListView.selfSizedHeight(
            sessionCount: 4, usageLimits: [], background: .graphite, style: WidgetStyle(scale: 2))

        XCTAssertGreaterThan(large, small * 1.5, "four rows at twice the size are not nearly twice as tall")
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

        XCTAssertGreaterThan(list.hiddenSessions.below, -1)
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
        usageLimits: [AgentUsageLimits] = [],
        style: WidgetStyle = .standard
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
            style: style,
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
