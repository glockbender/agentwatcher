import AgentWatchCore
import AppKit

/// How much room the session's own name gets in a row.
enum SessionTitleDisplay: Equatable {
    /// The whole name fits.
    case fullName
    /// The name is capped at this width and shortened in the middle, keeping both ends
    /// readable. The width is explicit because a label only truncates against a width it
    /// has actually been given; left to itself it grows and the row scrolls sideways.
    case truncated(toWidth: CGFloat)
    /// Only a first letter and an ellipsis fit. It is still something to hover, and still
    /// tells two neighbouring rows apart, which is more than an empty space does.
    case initial
    /// There is no name to show at all.
    case hidden
}

/// Picks the widest treatment that fits. Kept free of any view so the breakpoints can be
/// tested directly instead of by inspecting a rendered window.
///
/// - Parameter availableWidth: room left for the name once everything else in the row has
///   taken its share.
func chooseTitleDisplay(
    availableWidth: CGFloat,
    fullTitleWidth: CGFloat,
    minimumTitleWidth: CGFloat
) -> SessionTitleDisplay {
    guard fullTitleWidth > 0 else {
        return .hidden
    }
    if availableWidth >= fullTitleWidth {
        return .fullName
    }
    guard availableWidth >= minimumTitleWidth else {
        return .initial
    }
    return .truncated(toWidth: availableWidth)
}

/// One session, laid out as `[focus] [timer] [lamp] [icons] [name] [counts] [dismiss]`.
///
/// The focus button leads the row so that everything after it lines up into columns down the
/// list. The dismiss button stays at the far end instead of joining it: it exists only for a
/// session that has stopped, and reserving its width in every row put a visible hole between
/// the button and the timer for the sake of an alignment nothing else needed.
///
/// Everything up to the name has a width of its own; only the name gives way, so a narrow
/// widget never turns a count or a timer into something ambiguous.
///
/// Every picture in the row carries its own tooltip, because a picture that cannot be read
/// is worse than the word it replaced. The name is the exception in both directions: it
/// explains itself when it is fully visible and gets no tooltip then, and it keeps one
/// whenever anything was cut away.
@MainActor
final class HUDSessionRowView: NSStackView {
    /// Below this a shortened name says nothing useful, and a single initial takes over.
    /// Kept small on purpose: a truncated `AGENTS…CLAUDE.md` still identifies a session.
    static let minimumTitleWidth: CGFloat = 52
    static let elementSpacing: CGFloat = 4
    /// Tighter than the rest of the row. A bezelled button already carries visible padding
    /// inside its own edge, so the ordinary gap after it read as a hole.
    static let buttonGap: CGFloat = 2
    static let buttonWidth: CGFloat = 22
    /// A row's two action buttons, both exactly this size. As tall as the row, because they
    /// are what makes it that tall.
    static var buttonSize: NSSize { NSSize(width: buttonWidth, height: rowHeight) }
    /// Breathing room inside the hover wash.
    static let hoverPadding: CGFloat = 4

    /// The height of a row, which is the height of its buttons — they are the tallest thing
    /// in it. Both the buttons and the widget's self-sizing height are held to this, so a row
    /// is exactly as tall as the space reserved for it. It used to be called `approximate`,
    /// from when the sizing only estimated; a test now measures the two against each other.
    static let rowHeight: CGFloat = 19
    /// Three characters, always — the longest value the timer can print. Reserved in every
    /// row so the lamp and everything after it stand in a straight column.
    static let timerWidth: CGFloat = labelWidth(of: "99d", font: WidgetStyle.timerFont)

    /// Everything in this row except the name, including the gap the name would sit after.
    ///
    /// Measured by laying the row out rather than by adding up the parts. Adding them up was
    /// wrong twice over — an application icon draws at its own size rather than the one asked
    /// for, and a label is wider than its glyphs — and both mistakes made the name budget
    /// larger than the room the row really had.
    ///
    /// Only meaningful before `setTitle` is called, which is the whole reason a row starts
    /// without a name: the budget for the name is measured on the row that will carry it,
    /// so no second row has to be built and thrown away to find it out.
    var furnitureWidth: CGFloat {
        fittingSize.width + Self.elementSpacing
    }

    /// Kept so the row can refresh its own timer without being rebuilt. Rebuilding the list
    /// on every tick destroyed the view under the pointer twice a second, and a tooltip needs
    /// roughly a second of hovering over a view that is still there to appear at all.
    let snapshot: SessionSnapshot
    private let background: WidgetBackground
    private let timerLabel: NSTextField
    /// What the timer currently reads, so a tick that changes nothing writes nothing.
    private var shownElapsed: String
    private var shownColor: NSColor?

    private let onHoverChanged: (HUDSessionRowView, Bool) -> Void
    private var hoverTracking: NSTrackingArea?
    /// Where the name is inserted, and what holds the row's slack until it is.
    private let spacer = HUDSessionRowView.makeSpacer()
    private var hasTitle = false

    init(
        snapshot: SessionSnapshot,
        now: Date,
        background: WidgetBackground,
        lampScheme: LampScheme,
        onFocus: @escaping () -> Void,
        onRemove: (() -> Void)?,
        onHoverChanged: @escaping (HUDSessionRowView, Bool) -> Void = { _, _ in }
    ) {
        let lamp = SessionLamp.appearance(for: snapshot, scheme: lampScheme)
        self.snapshot = snapshot
        self.background = background
        self.onHoverChanged = onHoverChanged
        timerLabel = Self.makeTimer(for: snapshot, now: now, background: background)
        shownElapsed = timerLabel.stringValue
        shownColor = timerLabel.textColor
        super.init(frame: .zero)

        var views: [NSView] = [
            Self.makeFocusButton(for: snapshot, onFocus: onFocus),
            timerLabel,
            Self.makeLamp(lamp),
            Self.makeSourceIcon(for: snapshot),
        ]

        if let clientIcon = Self.makeClientIcon(for: snapshot, background: background) {
            views.append(clientIcon)
        }

        // Beside the identity rather than out with the counters: it qualifies everything
        // else in the row, and a marker at the far end would be read as one more count.
        if let faultMarker = Self.makeFaultMarker(for: snapshot, background: background) {
            views.append(faultMarker)
        }

        // All the slack in the row collects here, so everything after it sits against the
        // right edge. Without it the counters followed the name, which is a different length
        // in every row and changes with the work — the same number then appeared at a
        // different place in each row, and moved as soon as a name was shortened.
        //
        // It is also where the name is inserted later: the name comes before the counters,
        // not after. Counters appear and disappear with the work — a tool call starts, a
        // subagent finishes — and with them ahead of the name the name slid sideways every
        // few seconds. Behind it, they move instead, and the thing a reader is actually
        // looking for keeps one place in every row.
        views.append(spacer)

        for counter in activityCounts(for: snapshot) {
            views.append(
                Self.makeCounter(
                    image: ActivityIcon.image(for: counter.kind),
                    text: counterText(for: counter.kind, count: counter.count),
                    background: background
                )
            )
        }
        if let context = widgetContextText(for: snapshot) {
            views.append(
                Self.makeCounter(image: Self.contextImage, text: context, background: background)
            )
        }

        if let onRemove {
            let removeButton = RowActionButton(.dismiss, perform: onRemove)
            removeButton.pinSize(to: Self.buttonSize)
            views.append(removeButton)
        }

        for view in views {
            addArrangedSubview(view)
        }
        orientation = .horizontal
        alignment = .centerY
        spacing = Self.elementSpacing
        // Room for the hover wash to sit around the content rather than against it. The
        // list's own inset is reduced by as much, so nothing moves.
        edgeInsets = NSEdgeInsets(top: 1, left: Self.hoverPadding, bottom: 1, right: Self.hoverPadding)
        if let focusButton = views.first {
            setCustomSpacing(Self.buttonGap, after: focusButton)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Gives the row its name, at whatever length the measured budget allows.
    ///
    /// Separate from `init` because the budget is `furnitureWidth`, which can only be asked
    /// of a row that exists. Taking the name in `init` meant building a whole second row per
    /// session on every refresh purely to measure it, and throwing it away.
    ///
    /// Called once, and enforced rather than assumed: a second call would insert a second
    /// label beside the first, and `furnitureWidth` no longer means anything once a name is
    /// in place. A row that needs a different name is a row that gets rebuilt.
    func setTitle(_ title: String?, display: SessionTitleDisplay) {
        guard !hasTitle else {
            return
        }
        hasTitle = true
        guard
            let index = arrangedSubviews.firstIndex(of: spacer),
            let title = Self.makeTitle(title, display: display, background: background)
        else {
            return
        }
        insertArrangedSubview(title.label, at: index)
        title.cap?.isActive = true
    }

    private static let contextImage: NSImage? = {
        let image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Context window")
        image?.isTemplate = true
        return image
    }()

    /// A view with no content that gives up its width last and takes any surplus first.
    ///
    /// `greaterThanOrEqualToConstant: 0` rather than no constraint at all: a stack view needs
    /// something to solve for, and zero is the right minimum — in a row too narrow to hold
    /// its own contents there is no surplus to give.
    static func makeSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)])
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    /// Pressable unless the session is one that has no window at all.
    ///
    /// Pressable is the default, and a decision rather than an omission: a grey control would
    /// say "this session cannot be reached", which is nearly never true — the host is usually
    /// running, and when it is not, the row's card says so in a sentence a person can act on.
    /// Where the host is only holds while nothing moves, so a button greyed on that answer
    /// greys rows that are perfectly reachable a second later.
    ///
    /// `SessionPresence.canBeBroughtForward` is where an exception would be named; there is
    /// none today — a background session's press opens a terminal tab instead of raising a
    /// window. Were one to come back, the button would stay in place for it rather than
    /// disappear: the row would otherwise lose its first column and stop lining up with every
    /// other row, and the card would say why it is grey.
    ///
    /// No tooltip: the card is the one thing that explains a row.
    private static func makeFocusButton(for snapshot: SessionSnapshot, onFocus: @escaping () -> Void) -> NSButton {
        let button = RowActionButton(.focus, perform: onFocus)
        button.isEnabled = SessionPresence.canBeBroughtForward(snapshot)
        button.pinSize(to: buttonSize)
        return button
    }

    /// `.activeAlways` is the whole point: the widget is hovered while another application
    /// is in front, and a tracking area that only worked in the key window would report
    /// nothing exactly when the card is wanted.
    ///
    /// The area covers the row's information, not its buttons. Aiming at a button is aiming
    /// at a button — a card opening under the pointer there would be in the way of the very
    /// click it interrupted.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: Self.hoverRect(in: bounds, avoiding: buttonFrames()),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    private func buttonFrames() -> [NSRect] {
        arrangedSubviews.compactMap { $0 as? RowActionButton }.map(\.frame)
    }

    /// What is left of a row once its buttons are taken out of it.
    ///
    /// The buttons sit at the two ends, so the answer is the span between them. Kept free of
    /// any view so the arithmetic can be checked without building a window.
    static func hoverRect(in bounds: NSRect, avoiding buttonFrames: [NSRect]) -> NSRect {
        guard !buttonFrames.isEmpty else {
            return bounds
        }
        let leading = buttonFrames.filter { $0.midX < bounds.midX }.map(\.maxX).max() ?? bounds.minX
        let trailing = buttonFrames.filter { $0.midX >= bounds.midX }.map(\.minX).min() ?? bounds.maxX
        guard trailing > leading else {
            return .zero
        }
        return NSRect(x: leading, y: bounds.minY, width: trailing - leading, height: bounds.height)
    }

    override func mouseEntered(with event: NSEvent) {
        setHighlighted(true)
        onHoverChanged(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
        onHoverChanged(self, false)
    }

    /// The card takes half a second to appear, and a row that showed nothing until then left
    /// the pointer with no sign it was over anything at all.
    func setHighlighted(_ isHighlighted: Bool) {
        wantsLayer = true
        layer?.cornerRadius = WidgetStyle.rowCornerRadius
        layer?.backgroundColor = isHighlighted ? background.hoverColor.cgColor : NSColor.clear.cgColor
    }

    /// Where this row sits on screen, for a card that has to be placed beside it.
    var frameOnScreen: NSRect? {
        window?.convertToScreen(convert(bounds, to: nil))
    }

    /// Restates the elapsed time on the existing label, and only when it reads differently.
    /// Answers whether it wrote anything. Everything else in a row changes only when an event
    /// arrives, and an event rebuilds the list anyway.
    ///
    /// Writing the same string to a label is not free: it marks the label for redraw, and a
    /// redraw here means re-blurring the translucent panel behind it. The label's width is
    /// fixed at three characters, so this costs no layout — only drawing, which is why the
    /// guard is worth having and why the saving is not visible in a layout counter.
    ///
    /// Measured over five simulated minutes of eight rows: 96 of 2400 ticks read
    /// differently. The other 2304 would have redrawn the same three characters.
    @discardableResult
    func refreshTimer(now: Date) -> Bool {
        var wrote = false

        let elapsed = compactElapsed(now.timeIntervalSince(snapshot.lastObservedAt))
        if elapsed != shownElapsed {
            shownElapsed = elapsed
            timerLabel.stringValue = elapsed
            wrote = true
        }

        let color = Self.timerColor(for: snapshot, now: now, background: background)
        if color != shownColor {
            shownColor = color
            timerLabel.textColor = color
            wrote = true
        }

        return wrote
    }

    /// How long the session has been silent, in the colour of what that silence means.
    ///
    /// This is what replaced the `⚠ no fresh activity` suffix: the same judgement, in three
    /// characters instead of twenty, and with the number a reader wanted anyway.
    ///
    /// It holds three characters whatever it prints, and the value sits at the right of them,
    /// the way a clock reads. The alternative — a box the width of its own value — left the
    /// lamps and icons of neighbouring rows at different places, which is worse than the one
    /// character of slack a two-character value leaves behind.
    private static func makeTimer(
        for snapshot: SessionSnapshot,
        now: Date,
        background: WidgetBackground
    ) -> NSTextField {
        let elapsed = compactElapsed(now.timeIntervalSince(snapshot.lastObservedAt))
        let label = NSTextField(labelWithString: elapsed)
        label.font = WidgetStyle.timerFont
        label.alignment = .right
        label.textColor = timerColor(for: snapshot, now: now, background: background)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let insets = label.alignmentRectInsets
        label.widthAnchor.constraint(
            equalToConstant: max(0, timerWidth - insets.left - insets.right)
        ).isActive = true
        return label
    }

    /// Freshness only tracks the phases where silence is a question — a session in one of
    /// the others is silent for a reason the lamp already gives, and its timer stays plain.
    ///
    /// `no signal` is the exception, and an explicit one. That phase *is* a statement about
    /// how long nothing has been heard, yet freshness stops tracking it the moment it is
    /// reached, so inheriting the colour from freshness would have printed the age of a
    /// session nobody can vouch for in the same grey as one that answered a second ago.
    private static func timerColor(
        for snapshot: SessionSnapshot,
        now: Date,
        background: WidgetBackground
    ) -> NSColor {
        guard snapshot.phase != .disconnected else {
            return .systemOrange
        }
        return switch SessionFreshnessEvaluator.evaluate(snapshot, now: now) {
        case .current: background.secondaryForegroundColor
        case .quiet: .systemYellow
        case .noRecentActivity: .systemOrange
        }
    }

    private static func makeLamp(_ appearance: SessionLampAppearance) -> NSView {
        SessionLampView(appearance: appearance)
    }

    private static func makeSourceIcon(for snapshot: SessionSnapshot) -> NSView {
        let icon = NSImageView()
        icon.image = AgentIcon.image(for: snapshot.source)
        icon.imageScaling = .scaleProportionallyDown
        icon.pinSize(to: AgentIcon.size)
        return icon
    }

    private static func makeClientIcon(for snapshot: SessionSnapshot, background: WidgetBackground) -> NSView? {
        guard let clientKind = snapshot.clientKind, let image = SessionClientIcon.image(for: clientKind) else {
            return nil
        }
        let icon = NSImageView()
        icon.image = image
        icon.contentTintColor = background.clientColor(for: clientKind)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.pinSize(to: WidgetStyle.rowGlyph)
        return icon
    }

    /// The one mark that is about the widget rather than about the session: it says this row
    /// may be out of date. Spelled out in the hover card, like everything else in the row.
    static func makeFaultMarker(for snapshot: SessionSnapshot, background: WidgetBackground) -> NSView? {
        guard let fault = snapshot.monitoringFault else {
            return nil
        }
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: monitoringFaultSummary(for: fault)
        )
        icon.image?.isTemplate = true
        icon.contentTintColor = background.warningColor
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.pinSize(to: WidgetStyle.rowGlyph)
        return icon
    }

    /// A symbol and its number. Neither carries a tooltip: the row's hover card names every
    /// counter in words, which is one place to look instead of four small targets to find.
    private static func makeCounter(image: NSImage?, text: String?, background: WidgetBackground) -> NSView {
        let symbol = NSImageView()
        symbol.image = image
        symbol.contentTintColor = background.secondaryForegroundColor
        symbol.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        symbol.pinSize(to: ActivityIcon.size)

        guard let text else {
            return symbol
        }

        let label = NSTextField(labelWithString: text)
        label.font = WidgetStyle.countsFont
        label.textColor = background.foregroundColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        let pair = NSStackView(views: [symbol, label])
        pair.orientation = .horizontal
        pair.alignment = .centerY
        pair.spacing = 2
        pair.setContentCompressionResistancePriority(.required, for: .horizontal)
        pair.setContentHuggingPriority(.required, for: .horizontal)
        return pair
    }

    /// The name, at whatever length it was granted, plus the constraint that enforces it.
    ///
    /// A tooltip appears only when something was cut away. Repeating a name the reader can
    /// already see would train them to ignore the tooltips that do carry something.
    private static func makeTitle(
        _ title: String?,
        display: SessionTitleDisplay,
        background: WidgetBackground
    ) -> (label: NSTextField, cap: NSLayoutConstraint?)? {
        guard display != .hidden, let title, !title.isEmpty else {
            return nil
        }

        let shown =
            switch display {
            case .initial: "\(title.prefix(1))…"
            default: title
            }
        let label = NSTextField(labelWithString: shown)
        label.font = WidgetStyle.titleFont
        label.textColor = background.foregroundColor
        label.lineBreakMode = .byTruncatingMiddle

        var cap: NSLayoutConstraint?
        if case let .truncated(width) = display {
            // A label truncates only against a width it has been given. Its own compression
            // resistance has to give way for the cap to bind, and the cap is an upper bound
            // rather than an equality so a short name still takes only the room it needs.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // Auto Layout constrains a view's alignment rectangle, and a label's frame is
            // wider than that by its own insets. Capping the alignment rect at the budget
            // let the frame overrun it by those few points — enough to push a row past the
            // width it had just been measured to fit.
            let insets = label.alignmentRectInsets
            cap = label.widthAnchor.constraint(
                lessThanOrEqualToConstant: max(0, width - insets.left - insets.right)
            )
        } else {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return (label, cap)
    }
}

/// The small bezelled button a row uses for both of its actions.
///
/// One type rather than two that differed by a single character and the name of a callback.
@MainActor
final class RowActionButton: NSButton {
    enum Action: String {
        case focus = "↗"
        case dismiss = "×"
    }

    /// Read by the row's tests to tell the two buttons apart; the row itself never asks.
    let rowAction: Action
    private let perform: () -> Void

    init(_ rowAction: Action, perform: @escaping () -> Void) {
        self.rowAction = rowAction
        self.perform = perform
        super.init(frame: .zero)
        title = rowAction.rawValue
        bezelStyle = .texturedRounded
        controlSize = .small
        font = WidgetStyle.buttonFont
        target = self
        action = #selector(run)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc private func run() {
        perform()
    }
}
