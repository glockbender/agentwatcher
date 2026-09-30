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
        case .inactive: "limit reached, no signal, or never used for half an hour"
        case .broken: "its turn failed, or its terminal was closed under it"
        case .closed: "finished"
        }
    }
}

/// The settings window's order preview: a made-up day (`SessionOrderDemo`) played at an even
/// pace, one change every two seconds, with the rows sliding to their new places. Real rows,
/// built the way the widget builds them.
@MainActor
final class OrderPreviewPlayer: NSObject {
    private let settings: WidgetSettingsStore
    private let look: () -> WidgetTheme.Look
    private let background: () -> WidgetBackground
    private let opacity: () -> CGFloat
    private let rowLayouts: RowLayoutStore
    let preview = SessionOrderPreviewView()

    private var demo = SessionOrderDemo()
    private var demoOrdering = SessionOrdering()
    private var shownOrder: SessionOrder?
    private var shownBlocks: [SessionBlock] = []
    private var timer: Timer?
    private var isShown = false
    var isPlaying: Bool {
        timer != nil
    }

    init(
        settings: WidgetSettingsStore,
        look: @escaping () -> WidgetTheme.Look,
        background: @escaping () -> WidgetBackground,
        opacity: @escaping () -> CGFloat,
        rowLayouts: RowLayoutStore
    ) {
        self.settings = settings
        self.look = look
        self.background = background
        self.opacity = opacity
        self.rowLayouts = rowLayouts
        super.init()
        showCurrentValues()
    }

    /// Starts the list over when the order changed, and redraws it otherwise: the row, the
    /// background and the lamp it is drawn in are changed on the other panes.
    func showCurrentValues() {
        let order = settings.sessionOrder
        let blocks = settings.sessionBlockOrder
        if order != shownOrder || blocks != shownBlocks {
            shownOrder = order
            shownBlocks = blocks
            demo = SessionOrderDemo()
            demoOrdering = SessionOrdering()
        }
        showDemo(animated: false)
        updateTimer()
    }

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
        preview.setBackground(background(), opacity: opacity())
        preview.show(ordered, animated: animated, now: demo.now, rowFactory: makeRow)
    }

    private func makeRow(_ snapshot: SessionSnapshot, now: Date) -> HUDSessionRowView {
        let layout = rowLayouts.layout
        let row = HUDSessionRowView(
            snapshot: snapshot,
            now: now,
            background: background(),
            lampScheme: look().lampScheme,
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
    static var moveDuration: TimeInterval { ThemeInUse.timing.widget.rowMoveSeconds }

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

    private var backdrop: NSView?

    /// The widget's own panel — its material, colour and opacity — so the rows are seen on
    /// what they are drawn for.
    func setBackground(_ background: WidgetBackground, opacity: CGFloat) {
        backdrop?.removeFromSuperview()
        let panel = makeBackgroundView(for: background, opacity: opacity)
        panel.frame = bounds
        panel.autoresizingMask = [.width, .height]
        addSubview(panel, positioned: .below, relativeTo: nil)
        backdrop = panel
    }

    func show(
        _ sessions: [SessionSnapshot],
        animated: Bool,
        now: Date,
        rowFactory: (SessionSnapshot, Date) -> HUDSessionRowView
    ) {
        var next: [String: (row: HUDSessionRowView, snapshot: SessionSnapshot)] = [:]
        for snapshot in sessions {
            // A non-animated refresh also picks up settings changed on another tab. Equal
            // snapshots alone do not mean equal lamps, row layouts or background colours.
            if animated, let existing = rows[snapshot.id], existing.snapshot == snapshot {
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
