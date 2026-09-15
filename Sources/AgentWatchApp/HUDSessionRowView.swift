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

/// One session, laid out from a `RowLayout`: which parts, in what order, and which one of
/// them gives way when the widget is too narrow. `[timer] [lamp] [icon] [name] [counts]` is
/// what a template nobody has changed says, and what this row was before it took one.
///
/// The row is itself the way back to the session: a click anywhere on it brings the session
/// forward. It used to carry a `↗` button for that at its start, and the button was the one
/// thing on the row a person had to aim at; the row is the larger target and was already the
/// thing being read. The dismiss button stays at the far end as a button: it exists only for
/// a session that has stopped, and a click that both removes a row and brings its session
/// forward would be two actions on one press.
///
/// The timer holds a fixed width wherever it is put, so the parts beside it line up into
/// columns down the list.
///
/// Exactly one part gives way, and every other keeps its width, so a narrow widget never
/// turns a count or a timer into something ambiguous. ADR-0011 says why that is the app's
/// rule and not the person's.
///
/// Nothing in the row carries a tooltip of its own. The hover card explains the whole row in
/// words — every counter, the fault marker, how far a click will reach — which is one place to
/// look instead of a dozen small targets to find, and the one thing that names a shortened
/// name in full.
@MainActor
final class HUDSessionRowView: NSStackView {
    /// How far a press may travel and still be a click. Beyond it the press is a drag of the
    /// widget and is handed back to the window. Four points is about what a hand does on its
    /// own between pressing and releasing.
    ///
    /// The one measurement here that the widget's scale leaves alone: it is about the hand,
    /// not about the drawing, and a hand does not become steadier because the row got bigger.
    static let dragThreshold: CGFloat = 4

    /// Every size this row is drawn at. The rest of what used to be listed here — the row's
    /// height, its spacing, the width it reserves for the timer — moved onto it when those
    /// numbers stopped being constants; `WidgetStyle` says why they could not stay `static`.
    let style: WidgetStyle

    /// Everything in this row except the part that gives way, including the row's own gap.
    ///
    /// Measured by laying the row out rather than by adding up the parts. Adding them up was
    /// wrong twice over — an application icon draws at its own size rather than the one asked
    /// for, and a label is wider than its glyphs — and both mistakes made the name budget
    /// larger than the room the row really had.
    ///
    /// Only meaningful before `setFlexibleText` is called, which is the whole reason a row
    /// starts without that part: its budget is measured on the row that will carry it, so no
    /// second row has to be built and thrown away to find it out.
    var furnitureWidth: CGFloat {
        fittingSize.width + style.elementSpacing
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
    /// What holds the row's slack. `RowPart.gap` says why a row needs exactly one.
    private let spacer = HUDSessionRowView.makeSpacer()
    /// The parts this row actually put on screen, in order, including the one that gives way.
    ///
    /// Not the same list as `layout.parts`: a part the session cannot fill draws nothing. It
    /// is what tells `setFlexibleText` where to insert — counting the parts before the
    /// flexible one that really became views.
    private(set) var drawnParts: [RowPart] = []
    /// The part this row leaves out while it is measured, kept so `setFlexibleText` can find
    /// where to put it back.
    private var layoutFlexible: RowPart?
    private var hasTitle = false

    init(
        snapshot: SessionSnapshot,
        now: Date,
        background: WidgetBackground,
        lampScheme: LampScheme,
        layout: RowLayout = .standard,
        style: WidgetStyle = .standard,
        onFocus: @escaping () -> Void,
        dismissal: RowDismissal,
        onRemove: @escaping () -> Void,
        onHoverChanged: @escaping (HUDSessionRowView, Bool) -> Void = { _, _ in }
    ) {
        let lamp = SessionLamp.appearance(for: snapshot, scheme: lampScheme)
        self.snapshot = snapshot
        self.background = background
        self.lampScheme = lampScheme
        self.style = style
        self.onFocus = onFocus
        self.onHoverChanged = onHoverChanged
        timerLabel = Self.makeTimer(
            for: snapshot, now: now, background: background, lampScheme: lampScheme, style: style)
        shownElapsed = timerLabel.stringValue
        shownColor = timerLabel.textColor
        super.init(frame: .zero)

        var views: [NSView] = []
        var drawn: [RowPart] = []
        for part in layout.parts {
            // The part that gives way is left out here and inserted by `setFlexibleText`:
            // its width is decided from `furnitureWidth`, which is everything *but* it.
            guard part != layout.flexible else {
                drawn.append(part)
                continue
            }
            // A part the session has nothing to put in draws nothing rather than an empty
            // box. Most rows have no fault to show, and a reserved gap for one would spend
            // width on the absence of news.
            guard
                let view = makePart(
                    part,
                    snapshot: snapshot,
                    lamp: lamp,
                    layout: layout,
                    background: background,
                    style: style
                )
            else {
                continue
            }
            views.append(view)
            drawn.append(part)
        }
        drawnParts = drawn
        layoutFlexible = layout.flexible

        // A row that has stopped keeps its button whether or not it works yet, greyed until
        // it does. Taking the button away instead answered "is there a button?" when the
        // question a person asks is "why can I not close this?" — and the hover card is
        // where that one is answered, in words, with the moment it starts working.
        if case .notOffered = dismissal {
            // Nothing to dismiss: the session is at work, or waiting for a person. The
            // column can still be held open, so that what a row ends with — a counter, a
            // percentage — stands in the same place whether or not the session has stopped.
            // Empty rather than a disabled button: there is no action here to explain, and a
            // button nobody can ever press is a question the hover card would have to answer.
            if layout.reservesDismissColumn {
                let heldOpen = NSView()
                heldOpen.translatesAutoresizingMaskIntoConstraints = false
                heldOpen.pinSize(to: style.buttonSize)
                views.append(heldOpen)
            }
        } else {
            let removeButton = RowDismissButton(
                font: style.buttonFont,
                controlSize: style.buttonControlSize,
                hasBezel: style.buttonHasBezel,
                color: background.secondaryForegroundColor,
                perform: onRemove
            )
            removeButton.isEnabled = dismissal == .now
            removeButton.pinSize(to: style.buttonSize)
            views.append(removeButton)
        }

        for view in views {
            addArrangedSubview(view)
        }
        orientation = .horizontal
        alignment = .centerY
        spacing = style.elementSpacing
        heightAnchor.constraint(equalToConstant: style.rowHeight).isActive = true
        // Room for the hover wash to sit around the content rather than against it. The
        // list's own inset is reduced by as much, so nothing moves.
        edgeInsets = NSEdgeInsets(
            top: style.rowVerticalInset,
            left: style.hoverPadding,
            bottom: style.rowVerticalInset,
            right: style.hoverPadding
        )
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

    /// One part, or nothing when the session has nothing to put in it.
    ///
    /// The counters are one part and several views, which is why this returns a stack rather
    /// than a label: they are chosen together in the settings window, they keep a fixed order
    /// among themselves, and a person moving "counters" moves all of them at once.
    private func makePart(
        _ part: RowPart,
        snapshot: SessionSnapshot,
        lamp: SessionLampAppearance,
        layout: RowLayout,
        background: WidgetBackground,
        style: WidgetStyle
    ) -> NSView? {
        switch part {
        case .timer:
            return timerLabel
        case .lamp:
            return Self.makeLamp(lamp, style: style)
        case .agent:
            return Self.makeSourceIcon(for: snapshot, style: style)
        case .fault:
            return Self.makeFaultMarker(for: snapshot, background: background, style: style)
        case .gap:
            return spacer
        case .name, .project, .branch, .model, .host, .thread:
            return rowPartText(part, for: snapshot, layout: layout)
                .map { Self.makeWord($0, part: part, background: background, style: style) }
        case .counters:
            let counted = activityCounts(for: snapshot).filter { layout.counterKinds.contains($0.kind) }
            guard !counted.isEmpty else {
                return nil
            }
            let block = NSStackView(
                views: counted.map { counter in
                    Self.makeCounter(
                        image: ActivityIcon.image(for: counter.kind),
                        text: counterText(for: counter.kind, count: counter.count),
                        background: background,
                        style: style
                    )
                })
            block.orientation = .horizontal
            block.alignment = .centerY
            block.spacing = style.elementSpacing
            return block
        case .context:
            return widgetContextText(for: snapshot, style: layout.contextStyle).map {
                Self.makeCounter(image: Self.contextImage, text: $0, background: background, style: style)
            }
        }
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
    func setFlexibleText(_ text: String?, display: SessionTitleDisplay) {
        guard !hasTitle else {
            return
        }
        hasTitle = true
        if display != .hidden {
            accessibleName = text?.nonEmpty
        }
        guard
            let index = flexibleIndex,
            let label = Self.makeTitle(text, display: display, background: background, style: style)
        else {
            return
        }
        insertArrangedSubview(label.label, at: index)
        label.cap?.isActive = true
    }

    /// Where the part that gives way belongs among the views already here.
    ///
    /// Counted from `drawnParts` rather than found by looking for the spacer: the flexible
    /// part is wherever the template puts it, which may be on either side of the gap, and
    /// the parts before it are only those the session could actually fill.
    private var flexibleIndex: Int? {
        guard let flexible = drawnParts.first(where: { $0 == layoutFlexible }) else {
            return nil
        }
        return drawnParts.prefix(while: { $0 != flexible }).count
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
        lampScheme: LampScheme,
        style: WidgetStyle
    ) -> NSTextField {
        let elapsed = compactElapsed(now.timeIntervalSince(snapshot.lastObservedAt))
        let label = NSTextField(labelWithString: elapsed)
        label.font = style.timerFont
        label.alignment = .right
        label.textColor = timerColor(for: snapshot, now: now, background: background, lampScheme: lampScheme)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let insets = label.alignmentRectInsets
        label.widthAnchor.constraint(
            equalToConstant: max(0, style.timerWidth - insets.left - insets.right)
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

    private static func makeLamp(_ appearance: SessionLampAppearance, style: WidgetStyle) -> NSView {
        SessionLampView(appearance: appearance, diameter: style.lampDiameter)
    }

    /// Which agent, and nothing else. Where the session runs used to stand beside this as a
    /// second symbol and is the hover card's alone now — `SessionClientKind.displayName`
    /// records what was tried before that and why it was turned down.
    private static func makeSourceIcon(for snapshot: SessionSnapshot, style: WidgetStyle) -> NSView {
        let icon = NSImageView()
        icon.image = AgentIcon.image(for: snapshot.source, size: style.agentIconSize)
        icon.imageScaling = .scaleProportionallyDown
        icon.pinSize(to: style.agentIconSize)
        return icon
    }

    /// The one mark that is about the widget rather than about the session: it says this row
    /// may be out of date. Spelled out in the hover card, like everything else in the row.
    static func makeFaultMarker(
        for snapshot: SessionSnapshot,
        background: WidgetBackground,
        style: WidgetStyle = .standard
    ) -> NSView? {
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
        icon.symbolConfiguration = .init(pointSize: style.rowGlyphPointSize, weight: .regular)
        // Without this the box below is not obeyed. An `NSImageView` adds size constraints of
        // its own from the image it holds, and a symbol brings two — measured here as a
        // required 3.5 and 6 fighting the required 7 this asks for, which Auto Layout settled
        // at 9.5, half again the size, inside a row with no room for it. Told to scale down,
        // the view gives way instead. It went unseen while the row was 19 points tall and
        // anything that overran still fitted; at half that it is the row's tallest thing.
        icon.imageScaling = .scaleProportionallyDown
        icon.image?.size = style.rowGlyph
        icon.pinSize(to: style.rowGlyph)
        return icon
    }

    /// A symbol and its number. Neither carries a tooltip: the row's hover card names every
    /// counter in words, which is one place to look instead of four small targets to find.
    private static func makeCounter(
        image: NSImage?,
        text: String?,
        background: WidgetBackground,
        style: WidgetStyle
    ) -> NSView {
        let symbol = NSImageView()
        symbol.image = image
        symbol.contentTintColor = background.secondaryForegroundColor
        symbol.symbolConfiguration = .init(pointSize: style.activityIconPointSize, weight: .regular)
        // For the reason the fault marker gives: a symbol's own constraints outvote the box
        // unless the view is told it may scale down.
        symbol.imageScaling = .scaleProportionallyDown
        symbol.image?.size = style.activityIconSize
        symbol.pinSize(to: style.activityIconSize)

        guard let text else {
            return symbol
        }

        let label = NSTextField(labelWithString: text)
        label.font = style.countsFont
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
    /// A part that is one word of text and keeps its width.
    ///
    /// The name is the row's own subject and is drawn in the foreground colour; everything
    /// else here — the project, the branch, the model, where it runs, whose thread it is —
    /// qualifies it, and is drawn the way the counters are so that a glance finds the name
    /// first. That is the same rule the hover card follows, one line down.
    private static func makeWord(
        _ text: String,
        part: RowPart,
        background: WidgetBackground,
        style: WidgetStyle
    ) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = part == .name ? style.titleFont : style.countsFont
        label.textColor = part == .name ? background.foregroundColor : background.secondaryForegroundColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private static func makeTitle(
        _ title: String?,
        display: SessionTitleDisplay,
        background: WidgetBackground,
        style: WidgetStyle
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
        label.font = style.titleFont
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

    /// - Parameters:
    ///   - hasBezel: `false` where the widget is drawn too small for AppKit to draw one —
    ///     `WidgetStyle.buttonHasBezel` decides, and says what goes wrong otherwise. The box,
    ///     the click and the place at the end of the row are the same either way.
    ///   - color: what the bezel-less mark is drawn in; ignored when there is a bezel, which
    ///     takes the system's own control colour.
    init(
        font: NSFont = WidgetStyle.standard.buttonFont,
        controlSize: NSControl.ControlSize = WidgetStyle.standard.buttonControlSize,
        hasBezel: Bool = true,
        color: NSColor? = nil,
        perform: @escaping () -> Void
    ) {
        self.perform = perform
        super.init(frame: .zero)
        bezelStyle = .texturedRounded
        isBordered = hasBezel
        self.controlSize = controlSize
        self.font = font
        if hasBezel {
            title = "×"
        } else {
            Self.markWithASymbol(self, pointSize: font.pointSize, color: color)
        }
        target = self
        action = #selector(run)
    }

    /// The `×` as a symbol rather than as text, for a button with no bezel.
    ///
    /// Not a matter of taste — measured, on both a dark and a light widget. A disabled
    /// borderless button does not draw its title **at all**: with AppKit's own colour, with
    /// the widget's, at full strength and faded, every one came out as bare background, so a
    /// `×` that did not work yet was not merely faint but absent. The same button drawn with
    /// an image is drawn in both states, and AppKit dims the disabled one itself — measured
    /// against a light widget at 0.49 working and 0.75 not yet, where the background is 0.97.
    ///
    /// That matters more here than anywhere: a button that cannot work yet has to stay put
    /// and stay visible, because the question a person asks is "why can I not close this?"
    /// and the hover card answers it. A button that vanishes answers a different one.
    ///
    /// It also puts the mark in the same language as the rest of the row, which is symbols
    /// throughout — the counters, the fault marker — and leaves the bezelled `×` of the
    /// ordinary sizes exactly as it was.
    private static func markWithASymbol(_ button: NSButton, pointSize: CGFloat, color: NSColor?) {
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.symbolConfiguration = .init(pointSize: pointSize, weight: .regular)
        button.contentTintColor = color
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @objc private func run() {
        perform()
    }
}
