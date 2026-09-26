import AgentWatchCore
import AppKit

extension SessionOrder {
    var settingsTitle: String {
        switch self {
        case .arrival: "Arrival"
        case .recentActivity: "Recent activity"
        case .attention: "By state"
        case .blocks: "By blocks"
        }
    }

    /// What the order does, said beside its button rather than in a tooltip: the four are
    /// chosen between by reading them.
    var settingsExplanation: String {
        switch self {
        case .arrival: "In the order sessions arrived. A row never moves by itself."
        case .recentActivity: "Whatever was heard from last goes on top. The busiest of the four."
        case .attention: "Needs you, working, done, idle, closed — the latest to join a group on top."
        case .blocks: "Blocks in the order you arrange below — the latest to join a block on top."
        }
    }
}

extension SessionBlock {
    var settingsTitle: String {
        switch self {
        case .active: "Active"
        case .inactive: "Inactive"
        case .broken: "Broken"
        case .closed: "Closed"
        }
    }

    var settingsExplanation: String {
        switch self {
        case .active: "alive, in any state"
        case .inactive: "no signal, or opened and never asked a thing for half an hour"
        case .broken: "its turn failed, or its terminal was closed under it"
        case .closed: "finished"
        }
    }
}

/// The settings window's `Order` tab: which order, and what it looks like.
///
/// The answer to "what will my list do" is a list, as the row tab's answer is a row: real rows,
/// built the way the widget builds them. For the two orders where rows move by themselves the
/// list plays a made-up day (`SessionOrderDemo`) at an even pace, one change every two seconds,
/// and the rows slide to their new places. For the blocks the list is their builder: the blocks
/// in their order, each with the rows it would hold and arrows to move it.
@MainActor
final class SessionOrderTab: NSObject {
    let view = NSStackView()
    private let settings: WidgetSettingsStore
    private let backgroundStore: WidgetBackgroundStore
    private let lampSchemes: LampSchemeStore
    private let rowLayouts: RowLayoutStore

    /// Visible to the tests, which operate the tab the way a person does.
    private(set) var modeButtons: [SessionOrder: NSButton] = [:]
    private(set) var moveUpButtons: [SessionBlock: NSButton] = [:]
    private(set) var moveDownButtons: [SessionBlock: NSButton] = [:]
    /// The rows the builder shows under each block, by session.
    private(set) var builderRows: [SessionBlock: [String]] = [:]
    let preview = SessionOrderPreviewView()
    private let builder = NSStackView()
    private let caption = NSTextField(wrappingLabelWithString: "")

    private var demo = SessionOrderDemo()
    private var demoOrdering = SessionOrdering()
    private var timer: Timer?
    private var isShown = false
    /// Whether the demo is playing now — for the tests, and for nothing else.
    var isPlaying: Bool {
        timer != nil
    }

    init(
        settings: WidgetSettingsStore,
        backgroundStore: WidgetBackgroundStore,
        lampSchemes: LampSchemeStore,
        rowLayouts: RowLayoutStore
    ) {
        self.settings = settings
        self.backgroundStore = backgroundStore
        self.lampSchemes = lampSchemes
        self.rowLayouts = rowLayouts
        super.init()

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        view.addView(makeModeGrid(), in: .top)
        builder.orientation = .vertical
        builder.alignment = .leading
        builder.spacing = 6
        view.addView(preview, in: .top)
        view.addView(builder, in: .top)
        caption.font = WidgetStyle.standard.secondaryFont
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = SessionOrderPreviewView.width
        view.addView(caption, in: .top)
        let reset = NSButton(title: "Use the app's own order", target: self, action: #selector(resetOrder))
        reset.bezelStyle = .rounded
        reset.toolTip = "Puts back the arrival order, and the blocks in their first order."
        view.addView(reset, in: .top)
        showCurrentValues()
    }

    /// One radio button per order, each with what it does beside it.
    private func makeModeGrid() -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        for order in SessionOrder.allCases {
            let button = NSButton(
                radioButtonWithTitle: order.settingsTitle, target: self, action: #selector(modeChosen(_:)))
            button.tag = SessionOrder.allCases.firstIndex(of: order) ?? 0
            modeButtons[order] = button
            let explanation = NSTextField(labelWithString: order.settingsExplanation)
            explanation.font = WidgetStyle.standard.secondaryFont
            explanation.textColor = .secondaryLabelColor
            // A whole number of points. Left at its fitting width, two of the four came out
            // 306.5 and 390.5 wide and were drawn visibly darker than the other two, in the same
            // colour — found by drawing the tab, and gone once every width was whole.
            explanation.widthAnchor.constraint(equalToConstant: ceil(explanation.fittingSize.width)).isActive = true
            grid.addRow(with: [button, explanation])
        }
        return grid
    }

    // MARK: - Showing what is stored

    /// Everything read again from the settings: the order's button, and either its list or
    /// its builder.
    func showCurrentValues() {
        let order = settings.sessionOrder
        for (candidate, button) in modeButtons {
            button.state = candidate == order ? .on : .off
        }
        let isBuilder = order == .blocks
        preview.isHidden = isBuilder
        builder.isHidden = !isBuilder
        if isBuilder {
            showBuilder()
        } else {
            restartDemo()
        }
        caption.stringValue = Self.caption(for: order)
        updateTimer()
    }

    private static func caption(for order: SessionOrder) -> String {
        let held = "Rows hold their places while the pointer is over the widget."
        switch order {
        case .arrival:
            return "A made-up list. Nothing here moves by itself: a session keeps its place until it closes. \(held)"
        case .recentActivity, .attention:
            return "A made-up list, played one change every two seconds. \(held)"
        case .blocks:
            return
                "Move a block with its arrows. Every block is always there, so no session can drop out of the widget. \(held)"
        }
    }

    /// Shown, or not: the demo plays only while a person can see it, and only for an order
    /// whose rows move by themselves.
    func setShown(_ isShown: Bool) {
        self.isShown = isShown
        updateTimer()
    }

    private func updateTimer() {
        let plays = isShown && SessionOrderDemo.plays(settings.sessionOrder)
        guard plays != isPlaying else {
            return
        }
        guard plays else {
            timer?.invalidate()
            timer = nil
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: SessionOrderDemo.stepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceDemo()
            }
        }
    }

    // MARK: - The demo

    /// From the start, with an ordering of its own: the list shown is the one a person would
    /// see had they switched to this order with these sessions.
    private func restartDemo() {
        demo = SessionOrderDemo()
        demoOrdering = SessionOrdering()
        showDemo(animated: false)
    }

    /// One step of the demo, and the rows slide to wherever it puts them.
    func advanceDemo() {
        demo.advance()
        showDemo(animated: true)
    }

    private func showDemo(animated: Bool) {
        let ordered = demoOrdering.order(
            demo.sessions,
            mode: settings.sessionOrder,
            blocks: settings.sessionBlockOrder,
            now: demo.now
        )
        preview.setBackground(backgroundStore.selected)
        preview.show(ordered, animated: animated, now: demo.now, rowFactory: makeRow)
    }

    // MARK: - The builder

    /// The blocks in their order, each with its arrows, its name, what it holds, and the rows of
    /// the made-up list that fall into it — placed by `SessionBlock.of`, the same rule the
    /// widget follows, so the builder cannot disagree with it.
    private func showBuilder() {
        for view in builder.arrangedSubviews {
            builder.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        moveUpButtons.removeAll()
        moveDownButtons.removeAll()
        builderRows.removeAll()
        let blocks = settings.sessionBlockOrder
        let start = SessionOrderDemo()
        var ordering = SessionOrdering()
        let ordered = ordering.order(start.sessions, mode: .blocks, blocks: blocks, now: start.now)
        for (index, block) in blocks.enumerated() {
            builder.addArrangedSubview(makeBlockHeader(block, at: index, of: blocks.count))
            let sessions = ordered.filter { SessionBlock.of($0, now: start.now) == block }
            builderRows[block] = sessions.map(\.id)
            let rows = SessionOrderPreviewView()
            rows.setBackground(backgroundStore.selected)
            rows.show(sessions, animated: false, now: start.now, rowFactory: makeRow)
            builder.addArrangedSubview(rows)
        }
    }

    private func makeBlockHeader(_ block: SessionBlock, at index: Int, of count: Int) -> NSView {
        let up = NSButton(title: "↑", target: self, action: #selector(moveBlockEarlier(_:)))
        up.bezelStyle = .rounded
        up.tag = SessionBlock.allCases.firstIndex(of: block) ?? 0
        up.isEnabled = index > 0
        // Greyed is half the answer; the tooltip is the other half.
        up.toolTip = index > 0 ? "Move this block one place up" : "This block is already at the top"
        moveUpButtons[block] = up

        let down = NSButton(title: "↓", target: self, action: #selector(moveBlockLater(_:)))
        down.bezelStyle = .rounded
        down.tag = up.tag
        down.isEnabled = index < count - 1
        down.toolTip = index < count - 1 ? "Move this block one place down" : "This block is already at the bottom"
        moveDownButtons[block] = down

        let title = NSTextField(labelWithString: block.settingsTitle)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let explanation = NSTextField(labelWithString: block.settingsExplanation)
        explanation.font = WidgetStyle.standard.secondaryFont
        explanation.textColor = .secondaryLabelColor
        let header = NSStackView(views: [up, down, title, explanation])
        header.orientation = .horizontal
        header.spacing = 6
        return header
    }

    private func makeRow(_ snapshot: SessionSnapshot, now: Date) -> HUDSessionRowView {
        let layout = rowLayouts.layout
        let row = HUDSessionRowView(
            snapshot: snapshot,
            now: now,
            background: backgroundStore.selected,
            lampScheme: lampSchemes.scheme,
            layout: layout,
            onFocus: {},
            dismissal: SessionPresence.dismissal(of: snapshot, now: now),
            onRemove: {}
        )
        row.setFlexibleText(
            layout.flexible.flatMap { rowPartText($0, for: snapshot, layout: layout) },
            display: .fullName
        )
        return row
    }

    // MARK: - Actions

    @objc private func modeChosen(_ sender: NSButton) {
        guard SessionOrder.allCases.indices.contains(sender.tag) else {
            return
        }
        settings.setSessionOrder(SessionOrder.allCases[sender.tag])
        showCurrentValues()
    }

    @objc private func moveBlockEarlier(_ sender: NSButton) {
        moveBlock(ofTag: sender.tag, by: -1)
    }

    @objc private func moveBlockLater(_ sender: NSButton) {
        moveBlock(ofTag: sender.tag, by: 1)
    }

    private func moveBlock(ofTag tag: Int, by step: Int) {
        guard SessionBlock.allCases.indices.contains(tag) else {
            return
        }
        var blocks = settings.sessionBlockOrder
        guard let from = blocks.firstIndex(of: SessionBlock.allCases[tag]), blocks.indices.contains(from + step) else {
            return
        }
        blocks.swapAt(from, from + step)
        settings.setSessionBlockOrder(blocks)
        showBuilder()
    }

    @objc func resetOrder() {
        settings.setSessionOrder(.arrival)
        settings.setSessionBlockOrder(SessionBlock.defaultOrder)
        showCurrentValues()
    }
}

/// Real rows on the widget's background, placed by hand so that a move can be animated.
///
/// Not a `HUDSessionListView`: that list rebuilds a row whose session changed, and a new row
/// animated into place grows out of a corner. Here a rebuilt row starts where its old one
/// stood, and slides.
@MainActor
final class SessionOrderPreviewView: NSView {
    static let width: CGFloat = 380
    private static let inset: CGFloat = 4
    private static let spacing: CGFloat = 2
    /// How long a row takes to reach its new place: slow enough to follow, quick enough to be
    /// over before the next change two seconds later.
    static let moveDuration: TimeInterval = 0.45

    private var rows: [String: (row: HUDSessionRowView, snapshot: SessionSnapshot)] = [:]
    /// The sessions shown, top to bottom.
    private(set) var shownOrder: [String] = []
    private var height: CGFloat = 0

    override var isFlipped: Bool {
        true
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        wantsLayer = true
        layer?.cornerRadius = WidgetStyle.rowCornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: height)
    }

    /// The target row frame for each session, as the rows now stand.
    func frame(of sessionID: String) -> NSRect? {
        rows[sessionID]?.row.frame
    }

    /// The widget's own background, so the rows are seen on what they are drawn for.
    func setBackground(_ background: WidgetBackground) {
        layer?.backgroundColor = background.color.cgColor
    }

    func show(
        _ sessions: [SessionSnapshot],
        animated: Bool,
        now: Date,
        rowFactory: (SessionSnapshot, Date) -> HUDSessionRowView
    ) {
        var next: [String: (row: HUDSessionRowView, snapshot: SessionSnapshot)] = [:]
        for snapshot in sessions {
            if let existing = rows[snapshot.id], existing.snapshot == snapshot {
                next[snapshot.id] = existing
                continue
            }
            let row = rowFactory(snapshot, now)
            // Where its old row stood, so that it slides rather than appears.
            if let old = rows[snapshot.id] {
                row.frame = old.row.frame
                old.row.removeFromSuperview()
            }
            addSubview(row)
            next[snapshot.id] = (row, snapshot)
        }
        for (id, gone) in rows where next[id] == nil {
            gone.row.removeFromSuperview()
        }
        rows = next
        shownOrder = sessions.map(\.id)

        let rowWidth = Self.width - 2 * Self.inset
        var y = Self.inset
        var targets: [(HUDSessionRowView, NSRect)] = []
        for id in shownOrder {
            guard let row = rows[id]?.row else {
                continue
            }
            let height = row.fittingSize.height
            let target = NSRect(x: Self.inset, y: y, width: rowWidth, height: height)
            if row.frame.isEmpty {
                row.frame = target
            }
            targets.append((row, target))
            y += height + Self.spacing
        }
        height = y - Self.spacing + Self.inset
        invalidateIntrinsicContentSize()

        guard animated else {
            for (row, target) in targets {
                row.frame = target
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.moveDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (row, target) in targets {
                row.animator().frame = target
            }
        }
    }
}
