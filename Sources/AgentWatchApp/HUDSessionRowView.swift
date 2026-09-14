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

/// One session, laid out as `[timer] [lamp] [icons] [name] [counts] [dismiss]`.
///
/// The row is itself the way back to the session: a click anywhere on it brings the session
/// forward. It used to carry a `↗` button for that at its start, and the button was the one
/// thing on the row a person had to aim at; the row is the larger target and was already the
/// thing being read. The dismiss button stays at the far end as a button: it exists only for
/// a session that has stopped, and a click that both removes a row and brings its session
/// forward would be two actions on one press.
///
/// The timer leads the row at a fixed width, so everything after it lines up into columns
/// down the list.
///
/// Everything up to the name has a width of its own; only the name gives way, so a narrow
/// widget never turns a count or a timer into something ambiguous.
///
/// Nothing in the row carries a tooltip of its own. The hover card explains the whole row in
/// words — every counter, the fault marker, how far a click will reach — which is one place to
/// look instead of a dozen small targets to find, and the one thing that names a shortened
/// name in full.
@MainActor
final class HUDSessionRowView: NSStackView {
    /// Below this a shortened name says nothing useful, and a single initial takes over.
    /// Kept small on purpose: a truncated `AGENTS…CLAUDE.md` still identifies a session.
    static let minimumTitleWidth: CGFloat = 52
    static let elementSpacing: CGFloat = 4
    static let buttonWidth: CGFloat = 22
    /// The dismiss button, exactly this size. As tall as the row, so a row with one is no
    /// taller than a row without.
    static var buttonSize: NSSize { NSSize(width: buttonWidth, height: rowHeight) }
    /// Breathing room inside the hover wash.
    static let hoverPadding: CGFloat = 4
    /// How far a press may travel and still be a click. Beyond it the press is a drag of the
    /// widget and is handed back to the window. Four points is about what a hand does on its
    /// own between pressing and releasing.
    static let dragThreshold: CGFloat = 4

    /// The height of a row, which every row is held to whatever it holds. It used to follow
    /// from the buttons, the tallest thing in a row, until a row could have none; a row of
    /// icons and labels alone came out three points shorter than one with a dismiss button.
    /// The widget's self-sizing height reserves exactly this per row. It used to be called
    /// `approximate`, from when the sizing only estimated; a test now measures the two
    /// against each other.
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
    /// on every tick destroyed the view under the pointer twice a second, and the hover card
    /// needs half a second of hovering over a view that is still there to appear at all.
    let snapshot: SessionSnapshot
    private let background: WidgetBackground
    /// Kept because the timer's colour follows it, not only the lamp's — see `timerColor`.
    private let lampScheme: LampScheme
    private let timerLabel: NSTextField
    /// What the timer currently reads, so a tick that changes nothing writes nothing.
    private var shownElapsed: String
    private var shownColor: NSColor?

    private let onFocus: () -> Void
    /// What assistive technology hears the row called: the session's name as given to
    /// `setTitle`, whatever length the row itself could show of it.
    private var accessibleName: String?
    /// Where the press landed, in the row's coordinates, while it is still a click in the
    /// making. Cleared by the release and by a drag; a release the row never saw pressed is
    /// not a click.
    private var pressStart: NSPoint?
    /// Hands a press that travelled to the window as a drag, and says whether the window took
    /// it. It does not when the widget's position is locked, or when there is no window — and
    /// then the press is still a click: the lock exists to stop a stray drag, not the click.
    /// A closure so a test can state the answer without a window to drag.
    var beginWindowDrag: (NSEvent) -> Bool = { _ in false }

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
        dismissal: RowDismissal,
        onRemove: @escaping () -> Void,
        onHoverChanged: @escaping (HUDSessionRowView, Bool) -> Void = { _, _ in }
    ) {
        let lamp = SessionLamp.appearance(for: snapshot, scheme: lampScheme)
        self.snapshot = snapshot
        self.background = background
        self.lampScheme = lampScheme
        self.onFocus = onFocus
        self.onHoverChanged = onHoverChanged
        timerLabel = Self.makeTimer(for: snapshot, now: now, background: background, lampScheme: lampScheme)
        shownElapsed = timerLabel.stringValue
        shownColor = timerLabel.textColor
        super.init(frame: .zero)

        var views: [NSView] = [
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

        // A row that has stopped keeps its button whether or not it works yet, greyed until
        // it does. Taking the button away instead answered "is there a button?" when the
        // question a person asks is "why can I not close this?" — and the hover card is
        // where that one is answered, in words, with the moment it starts working.
        if case .notOffered = dismissal {
            // Nothing to dismiss: the session is at work, or waiting for a person.
        } else {
            let removeButton = RowDismissButton(perform: onRemove)
            removeButton.isEnabled = dismissal == .now
            removeButton.pinSize(to: Self.buttonSize)
            views.append(removeButton)
        }

        for view in views {
            addArrangedSubview(view)
        }
        orientation = .horizontal
        alignment = .centerY
        spacing = Self.elementSpacing
        heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        // Room for the hover wash to sit around the content rather than against it. The
        // list's own inset is reduced by as much, so nothing moves.
        edgeInsets = NSEdgeInsets(top: 1, left: Self.hoverPadding, bottom: 1, right: Self.hoverPadding)
        beginWindowDrag = { [weak self] event in
            guard let window = self?.window, window.isMovableByWindowBackground else {
                return false
            }
            window.performDrag(with: event)
            return true
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
        if display != .hidden {
            accessibleName = title?.nonEmpty
        }
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

    /// `.activeAlways` is the whole point: the widget is hovered while another application
    /// is in front, and a tracking area that only worked in the key window would report
    /// nothing exactly when the card is wanted.
    ///
    /// The area covers the row up to its dismiss button, not the button itself. Aiming at a
    /// button is aiming at a button — a card opening under the pointer there would be in the
    /// way of the very click it interrupted.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking {
            removeTrackingArea(hoverTracking)
        }
        let area = NSTrackingArea(
            rect: Self.hoverRect(in: bounds, before: dismissButtonFrame()),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    /// Present only on a row that can be dismissed; the one part of a row that is not the row.
    private var dismissButton: RowDismissButton? {
        arrangedSubviews.lazy.compactMap { $0 as? RowDismissButton }.first
    }

    private func dismissButtonFrame() -> NSRect? {
        dismissButton?.frame
    }

    /// What is left of a row once its dismiss button is taken out of it.
    ///
    /// The button sits at the trailing end, so the answer is everything before it. Kept free
    /// of any view so the arithmetic can be checked without building a window.
    static func hoverRect(in bounds: NSRect, before buttonFrame: NSRect?) -> NSRect {
        guard let buttonFrame else {
            return bounds
        }
        guard buttonFrame.minX > bounds.minX else {
            return .zero
        }
        return NSRect(x: bounds.minX, y: bounds.minY, width: buttonFrame.minX - bounds.minX, height: bounds.height)
    }

    /// The widget's panel never becomes key, so every click on it is a "first" click, and a
    /// view that declined those would never see one.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Every part of the row is the row, for a click. Left to AppKit, a label or an image
    /// view takes the press for itself — measured: the name, the timer, the lamp and both
    /// icons all did — and a click over the name would go nowhere. The dismiss button is the
    /// one part that keeps its own click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else {
            return nil
        }
        if let dismissButton, hit.isDescendant(of: dismissButton) {
            return hit
        }
        return self
    }

    /// The widget moves when its background is dragged, and a see-through view agrees to
    /// that by default. One press then does two things at once: the row hears it, and the
    /// window starts a drag with it. Measured in the running app with the default: a click
    /// that did not travel at all still shifted the widget while it brought the session
    /// forward. Refusing here keeps a click a click; `mouseDragged` hands a press that does
    /// travel back to the window, so the widget still moves when it is meant to.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    /// A click is a press and a release inside the same row. Fired on the release, the way a
    /// button fires, so a press that changes its mind and leaves the row does nothing.
    ///
    /// The second press of a double-click is not a second click. The first is still being
    /// carried out — for a background session that is a terminal tab being opened, and the
    /// rule that stops a second tab looks for the first tab's process, which takes longer to
    /// appear than the gap between two presses.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount <= 1 else {
            pressStart = nil
            return
        }
        pressStart = convert(event.locationInWindow, from: nil)
    }

    /// A press that travels is a move of the widget, as a press anywhere else on it would
    /// have been, and from then on it is not a click. Only when the widget can actually move:
    /// with the position locked nothing is dragged, and the press stays a click — a button
    /// fires on release inside its bounds however far the finger wandered, and so does this.
    override func mouseDragged(with event: NSEvent) {
        guard let pressStart else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressStart.x, point.y - pressStart.y) > Self.dragThreshold else {
            return
        }
        guard beginWindowDrag(event) else {
            return
        }
        self.pressStart = nil
    }

    override func mouseUp(with event: NSEvent) {
        guard pressStart != nil else {
            return
        }
        pressStart = nil
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onFocus()
    }

    // MARK: - Accessibility

    /// One element, and a button: the `↗` was one, and a row that took over its click takes
    /// over being something assistive technology can name and press. Its parts are read
    /// through the hover card, not one by one.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    /// Nothing but the `×`, and only where there is one. Left to AppKit a row that calls
    /// itself one element still hands out a child per label and per picture — measured, five
    /// of them on a row that has stopped — so the row would be a button with the parts of a
    /// button inside it. The dismiss button is the exception for the same reason it keeps its
    /// own click: it is a second action, and an action reachable only by pointing at it is an
    /// action some people do not have.
    override func accessibilityChildren() -> [Any]? {
        dismissButton.map { [$0] } ?? []
    }

    /// The session's name in full, or the bare fact of a session when the name is hidden by
    /// the setting or not known yet.
    override func accessibilityLabel() -> String? {
        accessibleName ?? "Session"
    }

    override func accessibilityPerformPress() -> Bool {
        onFocus()
        return true
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

        let color = Self.timerColor(for: snapshot, now: now, background: background, lampScheme: lampScheme)
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
        background: WidgetBackground,
        lampScheme: LampScheme
    ) -> NSTextField {
        let elapsed = compactElapsed(now.timeIntervalSince(snapshot.lastObservedAt))
        let label = NSTextField(labelWithString: elapsed)
        label.font = WidgetStyle.timerFont
        label.alignment = .right
        label.textColor = timerColor(for: snapshot, now: now, background: background, lampScheme: lampScheme)
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
        background: WidgetBackground,
        lampScheme: LampScheme
    ) -> NSColor {
        // The lamp's own colour, from the scheme a person can change. `no signal` is a phase,
        // and the lamp two points to the right is already drawing it; a second colour for the
        // same fact meant recolouring that lamp left this number the colour it used to be.
        guard snapshot.phase != .disconnected else {
            return lampScheme.style(for: .disconnected).color
        }
        return switch SessionFreshnessEvaluator.evaluate(snapshot, now: now) {
        case .current: background.secondaryForegroundColor
        case .quiet: WidgetStyle.timerQuiet
        case .noRecentActivity: WidgetStyle.timerStale
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
        // Where the session is read, not where it runs: a background session on screen in a
        // terminal wears the terminal's icon, because that is what a click on the row reaches.
        guard let clientKind = snapshot.hostKind, let image = SessionClientIcon.image(for: clientKind) else {
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
    /// A shortened name is spelled out in full by the hover card, never by a tooltip.
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

/// The small bezelled `×` at the end of a row that has stopped.
///
/// The one button left on a row. There used to be two of one type, told apart by a single
/// character; the other, `↗`, became the row itself.
@MainActor
final class RowDismissButton: NSButton {
    private let perform: () -> Void

    init(perform: @escaping () -> Void) {
        self.perform = perform
        super.init(frame: .zero)
        title = "×"
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
