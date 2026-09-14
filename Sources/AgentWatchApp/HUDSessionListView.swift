import AgentWatchCore
import AppKit

/// Not `final`, and the only class here that is not: `HUDOverflowTests` subclasses it to
/// count layout passes, which is the one way to see that a tick does not lay the list out.
@MainActor
class HUDSessionListView: NSView {
    /// Reduced by the row's own hover padding: the row carries that padding so the hover wash
    /// has room around its content, and the list gives back exactly as much. The text lands on
    /// `WidgetStyle.contentInset` either way, which is where the empty state puts its own.
    private static let horizontalInset: CGFloat = WidgetStyle.contentInset - HUDSessionRowView.hoverPadding

    static let rowSpacing: CGFloat = 4
    /// The gap above the first row and below the last. Read by the widget's self-sizing
    /// height as well, which is why there is one of these and not one per reader.
    static let verticalPadding: CGFloat = 6

    /// How much clear space a `+N` badge keeps from the widget's top or bottom edge and from
    /// its right edge. Less than the inset the rows keep, and that is the point: a badge lies
    /// over an end row, so every point it moves out of the rows' own column is a point of that
    /// row's `×` left to aim at.
    private static let badgeInset: CGFloat = 2

    /// What each row is currently showing, in the order the rows are in. Kept so the next
    /// report can be compared against it and only the rows that differ rebuilt.
    private var models: [HUDRowModel]
    private let usageLimits: [AgentUsageLimits]
    /// The moment the rows currently on screen were built against, which a row reads for the
    /// age it prints. Moved on by `apply`: a list outlives many events now, and a row rebuilt
    /// against the moment the list was created would state an age nobody asked about.
    private var now: Date
    private let availableWidth: CGFloat
    private let focus: (SessionSnapshot) -> Void
    private let remove: (SessionSnapshot) -> Void
    private let background: WidgetBackground
    private let lampScheme: LampScheme
    private let backgroundOpacity: CGFloat
    private let restoredScrollOffset: NSPoint?
    private let onScroll: (NSPoint) -> Void
    private let onHoverChanged: (HUDSessionRowView, Bool) -> Void

    /// How many sessions the counters are currently reporting as out of sight, each way.
    private(set) var hiddenSessions: HiddenRows = .none

    private var scrollView: NSScrollView?
    /// Both badges are built with the list and live for as long as it does, so neither is
    /// optional: `updateOverflowIndicator` runs inside a layout pass and may only write
    /// `isHidden` and a string there, never build a view or touch a constraint.
    private(set) var overflowBadgeAbove: HUDOverflowBadge
    private(set) var overflowBadgeBelow: HUDOverflowBadge
    private var hasRestoredScrollOffset = false

    init(
        models: [HUDRowModel],
        usageLimits: [AgentUsageLimits],
        now: Date,
        availableWidth: CGFloat,
        focus: @escaping (SessionSnapshot) -> Void,
        remove: @escaping (SessionSnapshot) -> Void,
        background: WidgetBackground,
        lampScheme: LampScheme,
        backgroundOpacity: CGFloat,
        restoredScrollOffset: NSPoint?,
        onScroll: @escaping (NSPoint) -> Void,
        onHoverChanged: @escaping (HUDSessionRowView, Bool) -> Void = { _, _ in }
    ) {
        self.models = models
        self.usageLimits = usageLimits
        self.now = now
        self.availableWidth = availableWidth
        self.focus = focus
        self.remove = remove
        self.background = background
        self.lampScheme = lampScheme
        self.backgroundOpacity = backgroundOpacity
        self.restoredScrollOffset = restoredScrollOffset
        self.onScroll = onScroll
        self.onHoverChanged = onHoverChanged
        self.overflowBadgeAbove = HUDOverflowBadge(background: background)
        self.overflowBadgeBelow = HUDOverflowBadge(background: background)
        super.init(frame: .zero)
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func buildContent() {
        let container = makeBackgroundView(for: background, opacity: backgroundOpacity)

        // Built nameless, measured, then named. Measuring happens here, while every row is
        // still detached: asking a view for its fitting size lays that view out, and a layout
        // pass started inside another one is what hung the widget once already. A row with no
        // superview and no window can only lay out itself, so this cannot reach the enclosing
        // pass whatever calls `init`.
        let rows = makeRows()
        let rowStack = FlippedStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = Self.rowSpacing
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = makeScrollView(documentView: rowStack)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        self.scrollView = scrollView
        container.addSubview(scrollView)

        // Over the list rather than under it. In the flow the counter took a strip of height
        // away from the very thing it reports on — the widget showed one row fewer for as
        // long as it was there, so it was partly the cause of what it announced. As a badge
        // it costs the list nothing, and the rows keep the whole widget.
        //
        // Their own views, and never in a stack: the count is taken after the rows have been
        // laid out, which is inside AppKit's own layout pass. Activating a constraint there
        // asks the layout engine to run while it is already running, which hung the widget
        // once — captured as `_layoutSubtreeWithOldSize:` recursing on itself. So both badges
        // are built once with their constraints and show and hide by `isHidden` alone.
        for badge in [overflowBadgeAbove, overflowBadgeBelow] {
            badge.isHidden = true
            container.addSubview(badge)
        }

        var constraints = [
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.horizontalInset),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.horizontalInset),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.verticalPadding),
            // Into the widget's own border, not in line with the rows. Wherever it sits a
            // badge covers part of an end row, and the right-hand end of a row is where its
            // `×` is — the only way to clear a session that has stopped. Out here it clears
            // most of that button instead of all of it, and the rows keep their own inset.
            overflowBadgeAbove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.badgeInset),
            overflowBadgeBelow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.badgeInset),
            // Nothing is ever above the list, whether or not there is a usage block below it,
            // so the counter for the rows scrolled past has one place and one only.
            overflowBadgeAbove.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.badgeInset),
            // The row stack must be free to exceed the clip view, otherwise a row that
            // cannot shrink any further would be clipped instead of scrolled to.
            rowStack.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
        ]

        // Each row is as wide as the visible area, so its trailing group — counters, context
        // size, the dismiss button — sits against the right edge and forms a column across
        // rows instead of ending wherever each name happens to end. A row whose contents
        // cannot fit keeps its own width, and scrolling reaches the rest of it.
        //
        // A constant, computed here, rather than a constraint against the clip view. Tying a
        // row to the clip view puts the row's width in the same equation as the widget's, and
        // measured on a 190 pt widget it resolved the wrong way round: the widget grew to
        // 235 pt to satisfy a row. The list is rebuilt whenever the width changes — it is an
        // input to `init` — so a constant cannot go stale.
        //
        // Also measured, for the record: with no per-row width at all every row took the
        // document's width, 207 pt, set by the one row that could not fit, and the dismiss
        // button of the rows that did fit landed at 180…204, just past the visible 178. The
        // row's own intrinsic width is no defence there — the flexible gap inside it barely
        // resists growing, which is exactly what makes the right edge work.
        //
        // A row built later — by the diff, for a session that has just arrived — is given the
        // same width the same way, in `widthConstraint(for:)`.
        constraints += rows.map(widthConstraint(for:))

        let usageStack = makeUsageStack()
        if let usageStack {
            let divider = NSBox()
            divider.boxType = .separator
            divider.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(divider)
            container.addSubview(usageStack)
            constraints += [
                divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.horizontalInset),
                divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.horizontalInset),
                divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Self.usageDividerGap),
                usageStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.horizontalInset),
                usageStack.trailingAnchor.constraint(
                    lessThanOrEqualTo: container.trailingAnchor,
                    constant: -Self.horizontalInset
                ),
                usageStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: Self.usageDividerGap),
                usageStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.verticalPadding),
                // The lower badge stops above the divider. What is under it there is a block
                // of account figures — not a row, and nothing announces it — so the badge may
                // have the gap before the separator and no more.
                overflowBadgeBelow.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -Self.badgeInset),
            ]
        } else {
            constraints += [
                // Must be an equality: the scroll view has no intrinsic height, so with only
                // its top pinned and a `lessThanOrEqualTo` at the bottom nothing would stretch
                // it and the list would collapse.
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.verticalPadding),
                // Nothing under the list but the widget's own edge, so the lower badge goes
                // all the way down into the corner.
                overflowBadgeBelow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.badgeInset),
            ]
        }

        addSubview(container)
        container.pinToEdges(of: self)
        NSLayoutConstraint.activate(constraints)
    }

    /// Whether this list can go on being used, or has to give way to one built afresh.
    ///
    /// What it cannot change once built: the width every row was measured against, the usage
    /// block under the divider, which is not made of rows, and the look — a lamp reads its
    /// colours once when it is built, so a recoloured phase reaches the screen only through a
    /// row built again. That last one is not reasoning but a measurement: `LampSchemeReachesTheWidgetTests`
    /// caught the diff leaving a repainted lamp on screen in its old colour.
    func canShow(
        usageLimits: [AgentUsageLimits],
        atWidth width: CGFloat,
        background: WidgetBackground,
        lampScheme: LampScheme,
        backgroundOpacity: CGFloat
    ) -> Bool {
        abs(width - availableWidth) < 0.5
            && usageLimits == self.usageLimits
            && background == self.background
            && lampScheme == self.lampScheme
            && backgroundOpacity == self.backgroundOpacity
    }

    /// Shows a new set of models, rebuilding only the rows that differ.
    ///
    /// Answers whether anything changed. The widget lays out either way; the tests read it.
    ///
    /// The rows that stay are the same objects they were, which is the point: the pointer
    /// keeps the row it was resting on, the hover card that was counting down survives, and the
    /// scroll position is never touched because the scroll view itself is never replaced.
    @discardableResult
    func apply(models newModels: [HUDRowModel], now: Date) -> Bool {
        guard let rowStack = scrollView?.documentView as? NSStackView else {
            return false
        }
        let update = rowListUpdate(from: models, to: newModels)
        // Before anything else, and whether or not the diff finds a change: a row that stays
        // reads its age from this moment, and the tick that would keep it current stops as
        // soon as no session claims work. Every event used to rebuild every row with a fresh
        // clock; a kept row is told the time instead. The same `now` is what a rebuilt row is
        // born with.
        self.now = now
        refreshTimers(now: now)
        guard !update.changesNothing else {
            return false
        }

        let rebuilt = Set(update.rebuilt)
        var rowsByID = Dictionary(
            rowStack.arrangedSubviews.compactMap { $0 as? HUDSessionRowView }.map { ($0.snapshot.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in update.removed + update.rebuilt {
            guard let row = rowsByID.removeValue(forKey: id) else {
                continue
            }
            rowStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        var constraints: [NSLayoutConstraint] = []
        let rows = newModels.map { model -> HUDSessionRowView in
            if !rebuilt.contains(model.id), let existing = rowsByID[model.id] {
                return existing
            }
            let row = makeRow(for: model)
            constraints.append(widthConstraint(for: row))
            return row
        }
        NSLayoutConstraint.activate(constraints)

        // Placed one by one rather than emptied and refilled: `insertArrangedSubview` moves a
        // view that is already arranged, and a row that keeps its place is never touched at
        // all. Emptying the stack first would take every surviving row out of the window and
        // put it back, which is exactly the disturbance this method exists to avoid.
        for (index, row) in rows.enumerated()
        where rowStack.arrangedSubviews.indices.contains(index)
            ? rowStack.arrangedSubviews[index] !== row : true
        {
            rowStack.insertArrangedSubview(row, at: index)
        }

        models = newModels
        return true
    }

    /// Each row is as wide as the visible area — see the note in `buildContent` for what a
    /// constraint against the clip view did instead.
    private func widthConstraint(for row: HUDSessionRowView) -> NSLayoutConstraint {
        row.widthAnchor.constraint(
            equalToConstant: max(availableWidth - 2 * Self.horizontalInset, row.fittingSize.width)
        )
    }

    /// Every row on screen, in the order they are shown.
    var rows: [HUDSessionRowView] {
        guard let rowStack = scrollView?.documentView as? NSStackView else {
            return []
        }
        return rowStack.arrangedSubviews.compactMap { $0 as? HUDSessionRowView }
    }

    /// The row currently showing this session, if it is on screen at all.
    func row(for sessionID: String) -> HUDSessionRowView? {
        guard let rowStack = scrollView?.documentView as? NSStackView else {
            return nil
        }
        return rowStack.arrangedSubviews
            .compactMap { $0 as? HUDSessionRowView }
            .first { $0.snapshot.id == sessionID }
    }

    /// Advances the elapsed time without rebuilding anything, and answers how many rows
    /// actually read differently.
    ///
    /// The list used to be rebuilt from scratch twice a second, which destroyed whatever the
    /// pointer was resting on and cancelled the hover card that was about to open. Only the
    /// timer changes between events, and a row can restate its own.
    ///
    /// The count is what makes the guard inside `HUDSessionRowView.refreshTimer` observable:
    /// a tick that changes nothing returns zero and draws nothing.
    @discardableResult
    func refreshTimers(now: Date) -> Int {
        guard let rowStack = scrollView?.documentView as? NSStackView else {
            return 0
        }
        return rowStack.arrangedSubviews
            .compactMap { $0 as? HUDSessionRowView }
            .reduce(into: 0) { total, row in
                total += row.refreshTimer(now: now) ? 1 : 0
            }
    }

    override func layout() {
        super.layout()
        restoreScrollOffsetIfNeeded()
        updateOverflowIndicator()
    }

    /// The count is taken once the rows have their final frames, which is after the subtree
    /// has been laid out — a count taken in `layout()` reads the previous size, because a
    /// parent lays out before its children do.
    ///
    /// Nothing here starts a layout pass of its own any more, and nothing here touches a
    /// constraint: the counter shows and hides inside a stack view.
    override func layoutSubtreeIfNeeded() {
        super.layoutSubtreeIfNeeded()
        updateOverflowIndicator()
    }

    /// Restores the scroll position after the first layout, not during `loadView`.
    ///
    /// Scrolling before the document view has been laid out is undone by that layout, and
    /// the resulting bounds change would be reported back as a scroll to the top — so the
    /// remembered offset was not merely ignored, it was overwritten with zero. The observer
    /// is attached only afterwards for the same reason.
    private func restoreScrollOffsetIfNeeded() {
        guard !hasRestoredScrollOffset, let scrollView else {
            return
        }
        hasRestoredScrollOffset = true

        if let restoredScrollOffset {
            scrollView.contentView.scroll(to: restoredScrollOffset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollOffsetChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func makeRows() -> [HUDSessionRowView] {
        models.map(makeRow(for:))
    }

    /// One row, built to show exactly what its model says.
    ///
    /// Every question the row used to answer from the clock — whether it offers a `×`, what
    /// name it carries — is already settled in the model, so two rows built from equal models
    /// are the same row and the diff is allowed to keep the one already on screen.
    private func makeRow(for model: HUDRowModel) -> HUDSessionRowView {
        let snapshot = model.snapshot
        let row = HUDSessionRowView(
            snapshot: snapshot,
            now: now,
            background: background,
            lampScheme: lampScheme,
            onFocus: { [focus] in focus(snapshot) },
            dismissal: model.dismissal,
            onRemove: { [remove] in remove(snapshot) },
            onHoverChanged: onHoverChanged
        )
        row.setTitle(model.name, display: titleDisplay(model.name, in: row))
        return row
    }

    /// Measures this row's own counts rather than a shared worst case, so a quiet row can
    /// still show its full name while a busy one truncates.
    ///
    /// Asked of the row that will carry the name. It used to be asked of a second row built
    /// for the measurement and discarded — two rows per session on every refresh, and the
    /// widget refreshes on every hook event.
    private func titleDisplay(_ name: String?, in row: HUDSessionRowView) -> SessionTitleDisplay {
        guard let title = name else {
            return .hidden
        }

        let contentWidth = availableWidth - 2 * Self.horizontalInset

        return chooseTitleDisplay(
            availableWidth: contentWidth - row.furnitureWidth,
            fullTitleWidth: labelWidth(of: title, font: WidgetStyle.titleFont),
            minimumTitleWidth: HUDSessionRowView.minimumTitleWidth
        )
    }

    private func makeScrollView(documentView: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Overlay even when the system is set to show scroll bars always. Measured: a legacy
        // scroller takes 15 points out of a 300-point widget and gives them to a bar, and the
        // width budget for the session name is computed against the full width — names would
        // be sized for room they do not have. The accessibility reason for that setting is
        // "make it visible that there is more", and this widget answers it better than a bar
        // does: a `+N` counter in either corner says how many sessions lie that way.
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // A scroll view in a window with a title bar inserts a top content inset of its own
        // so content does not slide under the bar. This widget hides that bar and draws
        // through it, so the inset is pure empty space — measured at 22 points, which was
        // more padding than the whole design allows for.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        return scrollView
    }

    @objc private func scrollOffsetChanged(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else {
            return
        }
        onScroll(clipView.bounds.origin)
        updateOverflowIndicator()
    }

    /// Auto-hiding scrollers vanish when the pointer is elsewhere, which is exactly when
    /// a hidden session most needs announcing. This says how many are out of sight each way.
    ///
    /// Counted from the rows' real frames rather than an assumed row height: an estimate
    /// that runs high would report nothing hidden while sessions were in fact cut off,
    /// which is the one failure this indicator exists to prevent.
    private func updateOverflowIndicator() {
        guard
            let scrollView,
            let rowStack = scrollView.documentView as? NSStackView
        else {
            return
        }

        let hidden = hiddenRows(
            rowFrames: rowStack.arrangedSubviews.map(\.frame),
            visibleRect: scrollView.documentVisibleRect
        )
        // Nothing is touched when nothing changed, and the widget lays out on every event.
        guard hidden != hiddenSessions else {
            return
        }
        // Per badge, not per pair: scrolling one row on usually moves one count and leaves
        // the other alone, and a label given the string it already holds is marked for
        // redraw all the same — which re-blurs the translucent panel behind it.
        if hidden.above != hiddenSessions.above {
            show(hidden.above, on: overflowBadgeAbove)
        }
        if hidden.below != hiddenSessions.below {
            show(hidden.below, on: overflowBadgeBelow)
        }
        hiddenSessions = hidden
    }

    /// Writes `isHidden` and a string and nothing else — this runs inside AppKit's own layout
    /// pass, where activating a constraint hung the widget once.
    private func show(_ count: Int, on badge: HUDOverflowBadge) {
        badge.isHidden = count == 0
        badge.label.stringValue = count == 0 ? "" : "+\(count)"
    }

    private func makeUsageStack() -> NSStackView? {
        Self.makeUsageStack(for: usageLimits, background: background)
    }

    /// How tall the widget should be for this many sessions.
    ///
    /// Lives here, beside the layout it measures. The controller used to re-derive it from
    /// three of this view's constants, which meant the window height and the content it
    /// framed could drift apart whenever either was touched.
    static func selfSizedHeight(
        sessionCount: Int,
        usageLimits: [AgentUsageLimits],
        background: WidgetBackground
    ) -> CGFloat {
        guard sessionCount > 0 else {
            return 0
        }
        // No trailing gap after the last row: the stack puts spacing between rows, not after
        // the final one, so counting a full row height per row would leave a blank strip.
        let rows =
            CGFloat(sessionCount) * (HUDSessionRowView.rowHeight + rowSpacing) - rowSpacing
        return 2 * verticalPadding + rows + usageHeight(for: usageLimits, background: background)
    }

    /// How much height the usage block needs, including the divider and the gaps around it.
    ///
    /// Built and measured rather than added up. The row cap, the font and the spacing are
    /// all decided in `makeUsageStack`, and a second copy of those numbers in the sizing
    /// code went stale the moment any of them changed.
    static func usageHeight(for usageLimits: [AgentUsageLimits], background: WidgetBackground) -> CGFloat {
        guard let stack = makeUsageStack(for: usageLimits, background: background) else {
            return 0
        }
        stack.layoutSubtreeIfNeeded()
        return stack.fittingSize.height + usageDividerHeight
    }

    /// The gap above and below the separator that introduces the usage block.
    private static let usageDividerGap: CGFloat = 4
    /// The separator itself.
    private static let separatorHeight: CGFloat = 1
    private static var usageDividerHeight: CGFloat { 2 * usageDividerGap + separatorHeight }

    private static func makeUsageStack(
        for usageLimits: [AgentUsageLimits],
        background: WidgetBackground
    ) -> NSStackView? {
        let usageRows =
            usageLimits
            .sorted { $0.source.rawValue < $1.source.rawValue }
            .prefix(2)
            .map { limits -> NSTextField in
                let label = NSTextField(labelWithString: widgetUsageText(for: limits))
                label.font = WidgetStyle.usageFont
                label.textColor = background.secondaryForegroundColor
                label.lineBreakMode = .byTruncatingTail
                return label
            }
        guard !usageRows.isEmpty else {
            return nil
        }

        let usageStack = NSStackView(views: usageRows)
        usageStack.orientation = .vertical
        usageStack.alignment = .leading
        usageStack.spacing = 2
        usageStack.translatesAutoresizingMaskIntoConstraints = false
        return usageStack
    }
}

/// The order rows appear in.
///
/// Live sessions keep the order they arrived in and never move. Sorting by the most recent
/// event instead kept lifting whichever session spoke last to the top, so a row moved out
/// from under the pointer every few seconds. Only a closed session changes place, sinking
/// below the live ones: it is finished, and retention is about to remove it anyway.
///
/// A disconnected session deliberately stays put. `no signal` is reversible — one event
/// brings it back — and sinking it would make it jump twice for nothing.
func orderedForDisplay(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
    sessions.sorted { left, right in
        if (left.phase == .sessionClosed) != (right.phase == .sessionClosed) {
            return right.phase == .sessionClosed
        }
        return left.arrivalIndex < right.arrivalIndex
    }
}

/// A `+N` counter, as a badge drawn over an end row rather than beside it.
///
/// A capsule because it lies on top of a session's own row: text alone on top of text reads
/// as part of the row it covers, and a rectangle reads as a broken row. The padding is the
/// least that keeps the shape from touching the letters — the badge is a label, not a
/// control, and anything more makes it look like one.
///
/// The count alone, without the arrow it used to carry: the corner it stands in already says
/// which way its rows lie, and the text is read over somebody's session name.
///
/// Takes no clicks: it sits over a row a person can hover, dismiss and scroll, and a badge
/// that swallowed those would take away more than it tells.
@MainActor
final class HUDOverflowBadge: NSView {
    private static let horizontalPadding: CGFloat = 4
    private static let verticalPadding: CGFloat = 1

    let label = NSTextField(labelWithString: "")

    init(background: WidgetBackground) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = WidgetStyle.overflowFont
        label.textColor = background.secondaryForegroundColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        wantsLayer = true
        // The widget's own background rather than a grey of its own, so the badge belongs to
        // whichever palette a person chose. Opaque, because what it covers is text.
        layer?.backgroundColor = background.color.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = background.secondaryForegroundColor.withAlphaComponent(0.25).cgColor

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        // An oval, whatever the font metrics turn out to be: half the height rather than a
        // radius chosen once and left to go wrong when the text size changes.
        layer?.cornerRadius = bounds.height / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// A stack whose first row sits at the top.
///
/// An `NSView` is not flipped by default, so a document view shorter than its scroll view
/// sinks to the bottom and leaves the slack above it. For a widget sized to its content
/// that read as a large and growing gap over the first session.
@MainActor
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Two numbers rather than one, because each of the two counters promises something
/// different: what scrolling on will reach, and what scrolling back will. One number counting
/// both ways stood at the bottom of a long list announcing five sessions that had already
/// been read, under an arrow pointing at nothing — so the counts were split rather than the
/// rows above simply dropped, and each corner now reports only what lies that way.
struct HiddenRows: Equatable {
    var above: Int
    var below: Int

    static let none = HiddenRows(above: 0, below: 0)
}

/// How much of a row has to lie past an edge before the row counts as hidden that way.
///
/// Any overhang at all used to be enough, and that read as a false alarm: a last row clipped
/// by a point or two is a row you can still read, while the counter over it said there was
/// something further down — which there was not. Nearly a third of a line gone is the point
/// where a row stops being a row you have read and starts being one you have to scroll to.
///
/// On the 19-point row this is 5.7 points. The fraction also covers the half-point a frame
/// can land off by, which a separate tolerance used to guard.
let hiddenRowFraction: CGFloat = 0.3

/// How many rows are out of sight each way, counted vertically.
///
/// Measured against each edge on its own, so a row hanging off the bottom is counted below
/// and nowhere else. A row cut at both ends at once therefore counts as neither — that needs
/// a clip view shorter than a single row, and at that size the widget has nothing to report
/// about anyway.
///
/// Only the vertical axis matters. A row wider than the clip view is reached by scrolling
/// sideways, not hidden — counting it made the indicator claim sessions were missing while
/// every one of them was on screen, and made widening the widget change a number that is
/// about vertical space.
///
/// Counted from the rows' real frames rather than an assumed row height: an estimate that
/// ran high would report nothing hidden while sessions were in fact cut off, which is the
/// one failure this count exists to prevent.
func hiddenRows(rowFrames: [NSRect], visibleRect: NSRect) -> HiddenRows {
    func isPast(_ overhang: CGFloat, of row: NSRect) -> Bool {
        overhang > row.height * hiddenRowFraction
    }
    return HiddenRows(
        above: rowFrames.filter { isPast(visibleRect.minY - $0.minY, of: $0) }.count,
        below: rowFrames.filter { isPast($0.maxY - visibleRect.maxY, of: $0) }.count
    )
}
