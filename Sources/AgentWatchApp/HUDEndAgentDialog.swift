import AppKit

/// The question a click on a broken session puts: its terminal is gone, its agent runs on,
/// and whether to end the agent is for the person who clicked (ADR-0013).
///
/// Drawn over the whole widget rather than as a window of its own. The panel never becomes
/// key, and a window here would take the focus from whatever is being worked in; an alert
/// would also activate the app.
///
/// The widget is darkened and the question stands on a card of its own: text over the
/// darkened rows alone was drawn and could not be read. Two layouts, chosen by the room the
/// widget has — a heading, a sentence and the buttons where they fit, and otherwise one line
/// over the buttons, on a card as large as the widget. The smallest widget is two rows tall,
/// and the second layout fits it at every size.
@MainActor
final class HUDEndAgentDialog: NSView {
    static let fadeDuration: TimeInterval = 0.15

    let sessionID: String
    let style: WidgetStyle
    private let card = NSView()
    private let heading = NSTextField(labelWithString: "Broken session")
    private let explanation: NSTextField
    private let shortQuestion = NSTextField(labelWithString: "Broken session. End it?")
    let cancelButton: HUDDialogButton
    let endButton: HUDDialogButton

    init(
        sessionID: String,
        sessionName: String?,
        style: WidgetStyle,
        onCancel: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.sessionID = sessionID
        self.style = style
        explanation = NSTextField(wrappingLabelWithString: Self.explanation(naming: sessionName))
        // One answer to a question: its buttons stay on screen while it fades, and a second
        // press on End would end the agent twice.
        let answer = OneAnswer()
        cancelButton = HUDDialogButton(
            title: "Cancel", fill: NSColor(calibratedWhite: 1, alpha: 0.18), style: style,
            perform: { answer.give(onCancel) })
        endButton = HUDDialogButton(title: "End", fill: .systemRed, style: style, perform: { answer.give(onEnd) })
        super.init(frame: .zero)
        // Dark whatever the widget's colour: the rows under it are darkened, and the card, its
        // text and its buttons are drawn for that.
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        layer?.cornerRadius = WidgetStyle.windowCornerRadius
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        card.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        card.layer?.borderWidth = 1
        addSubview(card)
        heading.font = .systemFont(ofSize: style.points(12), weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        explanation.font = style.secondaryFont
        explanation.textColor = NSColor(calibratedWhite: 1, alpha: 0.8)
        shortQuestion.font = .systemFont(ofSize: style.points(11), weight: .medium)
        shortQuestion.lineBreakMode = .byTruncatingTail
        for label in [heading, explanation, shortQuestion] {
            if label !== explanation {
                label.textColor = .white
            }
            label.alignment = .center
            card.addSubview(label)
        }
        card.addSubview(cancelButton)
        card.addSubview(endButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Short on purpose, and it names the session: the dialog covers the row that was
    /// clicked. The conversation is said to be kept, because "end" is otherwise read as
    /// losing it.
    static func explanation(naming name: String?) -> String {
        let subject = name.map { "“\($0)”" } ?? "This session"
        return "\(subject): its terminal is gone, but the agent still runs. End it? The conversation is kept."
    }

    /// Whether this size shows the one line over the buttons rather than the heading and the
    /// sentence.
    private(set) var isCompact = false

    /// Every length here is a whole number of points before it is used, not rounded after:
    /// a card centred by halves stood between two pixels, and on a screen of one pixel per
    /// point every line of text on it came out soft. Rounding a finished frame instead would
    /// narrow the sentence's box below the width it was measured at, and it could wrap onto a
    /// line the box has no room for.
    override func layout() {
        super.layout()
        let full = fullLayout(atWidth: bounds.width)
        isCompact = full.height > bounds.height
        heading.isHidden = isCompact
        explanation.isHidden = isCompact
        shortQuestion.isHidden = !isCompact

        if isCompact {
            layOutCompact(
                gap: full.gap, buttons: full.buttons, buttonHeight: full.buttonHeight, buttonsWidth: full.buttonsWidth)
            return
        }
        let cardHeight = full.contentHeight + 2 * full.padding
        card.frame = NSRect(
            x: half(bounds.width - full.cardWidth), y: half(bounds.height - cardHeight), width: full.cardWidth,
            height: cardHeight)
        card.layer?.cornerRadius = style.points(10)
        // Top to bottom; the view is not flipped, so the heading has the largest `y`.
        var y = cardHeight - full.padding - full.headingHeight
        heading.frame = NSRect(x: full.padding, y: y, width: full.textWidth, height: full.headingHeight)
        y -= full.gap + full.explanationHeight
        explanation.frame = NSRect(x: full.padding, y: y, width: full.textWidth, height: full.explanationHeight)
        y -= 2 * full.gap + full.buttonHeight
        place(
            full.buttons, from: half(full.cardWidth - full.buttonsWidth), y: y, height: full.buttonHeight, gap: full.gap
        )
    }

    /// How tall the question has to be at this width to show the heading and the sentence —
    /// for a menu, which gives a line the height it asks for rather than a size of its own.
    func heightShowingEverything(atWidth width: CGFloat) -> CGFloat {
        fullLayout(atWidth: width).height
    }

    private struct FullLayout {
        var gap: CGFloat
        var margin: CGFloat
        var padding: CGFloat
        var buttons: [NSSize]
        var buttonHeight: CGFloat
        var buttonsWidth: CGFloat
        var cardWidth: CGFloat
        var textWidth: CGFloat
        var headingHeight: CGFloat
        var explanationHeight: CGFloat
        var contentHeight: CGFloat
        var height: CGFloat { contentHeight + 2 * padding + 2 * margin }
    }

    /// The full layout: a card no wider than a sentence reads well at, centred.
    private func fullLayout(atWidth width: CGFloat) -> FullLayout {
        let gap = whole(style.points(6))
        let buttons = [cancelButton, endButton].map(\.intrinsicContentSize)
        let buttonHeight = buttons.map(\.height).max() ?? 0
        let margin = whole(style.points(10))
        let padding = whole(style.points(12))
        let cardWidth = min(width - 2 * margin, style.points(300)).rounded(.down)
        let textWidth = max(0, cardWidth - 2 * padding)
        let headingHeight = heading.intrinsicContentSize.height.rounded(.up)
        let explanationHeight =
            (explanation.cell?.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)
            ).height ?? 0).rounded(.up)
        return FullLayout(
            gap: gap, margin: margin, padding: padding, buttons: buttons, buttonHeight: buttonHeight,
            buttonsWidth: buttons.map(\.width).reduce(0, +) + gap, cardWidth: cardWidth, textWidth: textWidth,
            headingHeight: headingHeight, explanationHeight: explanationHeight,
            contentHeight: headingHeight + gap + explanationHeight + 2 * gap + buttonHeight)
    }

    /// The card takes the whole widget, the line over the buttons, both centred.
    private func layOutCompact(gap: CGFloat, buttons: [NSSize], buttonHeight: CGFloat, buttonsWidth: CGFloat) {
        let inset = whole(style.points(3))
        card.frame = NSRect(
            x: inset, y: inset, width: whole(bounds.width) - 2 * inset, height: whole(bounds.height) - 2 * inset)
        card.layer?.cornerRadius = max(0, WidgetStyle.windowCornerRadius - inset)
        let lineHeight = shortQuestion.intrinsicContentSize.height.rounded(.up)
        let lineGap = whole(gap / 2)
        let blockHeight = lineHeight + lineGap + buttonHeight
        let bottom = half(card.bounds.height - blockHeight)
        let side = whole(style.points(6))
        shortQuestion.frame = NSRect(
            x: side, y: bottom + buttonHeight + lineGap, width: max(0, card.bounds.width - 2 * side),
            height: lineHeight)
        place(buttons, from: half(card.bounds.width - buttonsWidth), y: bottom, height: buttonHeight, gap: gap)
    }

    private func place(_ sizes: [NSSize], from left: CGFloat, y: CGFloat, height: CGFloat, gap: CGFloat) {
        var x = left
        for (button, size) in zip([cancelButton, endButton], sizes) {
            button.frame = NSRect(x: x, y: y + half(height - size.height), width: size.width, height: size.height)
            x += size.width + gap
        }
    }

    private func whole(_ length: CGFloat) -> CGFloat {
        length.rounded()
    }

    /// Half of a length, for centring, kept on a whole point.
    private func half(_ length: CGFloat) -> CGFloat {
        (length / 2).rounded(.down)
    }

    /// The whole widget is the dialog's while it is open: a press anywhere but a button goes
    /// nowhere, rather than to the row under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else {
            return nil
        }
        return hit.isDescendant(of: cancelButton) || hit.isDescendant(of: endButton) ? hit : self
    }

    /// The panel never becomes key, so every click on it is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// A press on the darkened rows is not the start of a move, for the reason
    /// `HUDSessionRowView.mouseDownCanMoveWindow` gives.
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {}
}

/// A button drawn in full by itself, so it looks the same in a panel that is never key:
/// AppKit greys the colour of its own bezels in a window that is not.
@MainActor
final class HUDDialogButton: NSButton {
    private let fill: NSColor
    private let style: WidgetStyle
    private let perform: () -> Void

    init(title: String, fill: NSColor, style: WidgetStyle, perform: @escaping () -> Void) {
        self.fill = fill
        self.style = style
        self.perform = perform
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = style.points(5)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: style.points(11), weight: .medium), .foregroundColor: NSColor.white,
            ]
        )
        target = self
        action = #selector(run)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        // Whole points, for the reason `HUDEndAgentDialog.layout` gives.
        return NSSize(
            width: ceil(text.width) + 2 * style.points(12).rounded(),
            height: ceil(text.height) + 2 * style.points(4).rounded())
    }

    override var isHighlighted: Bool {
        didSet {
            updateFill()
        }
    }

    private func updateFill() {
        layer?.backgroundColor = (isHighlighted ? fill.shadow(withLevel: 0.25) ?? fill : fill).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    @objc private func run() {
        perform()
    }
}

/// The first answer, and only that one.
@MainActor
private final class OneAnswer {
    private var given = false

    func give(_ answer: () -> Void) {
        guard !given else {
            return
        }
        given = true
        answer()
    }
}
