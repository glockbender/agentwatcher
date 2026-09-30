import AppKit
import Carbon.HIToolbox

/// The menu line of a broken session: drawn by itself, because a click on it has to leave the
/// menu open for the question that follows (ADR-0013).
///
/// An ordinary menu line closes the menu on every click. A line whose item has a `view` gets
/// the click itself and the menu stays open — measured for the choice lines this app used to
/// have (ADR-0014), which is where this one comes from. What such a line gives up is the
/// drawing and the keyboard, done here.
///
/// Those lines lit up for the keyboard only, never under the pointer: their items had no
/// action, which a menu that enables its own items reads as disabled. This one's item has an
/// action, and the line keeps a hover of its own besides.
@MainActor
final class MenuBrokenSessionLineView: NSView {
    let title: String
    let image: NSImage?
    var onChoose: (() -> Void)?
    private(set) var isHovered = false

    /// The height of an ordinary menu line on the machine it was measured on.
    static let height: CGFloat = 22

    init(title: String, image: NSImage?) {
        self.title = title
        self.image = image
        let width = Self.textLeft(image: image) + Self.width(of: title) + Self.rightMargin
        super.init(frame: NSRect(x: 0, y: 0, width: max(200, ceil(width)), height: Self.height))
        // As wide as the menu makes its widest line, from this width up.
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func choose() {
        onChoose?()
    }

    override func mouseUp(with event: NSEvent) {
        choose()
    }

    /// Without this the menu keeps its keys to itself, and Return and Space do nothing.
    override var acceptsFirstResponder: Bool {
        true
    }

    /// Return, Space and the keypad's Enter choose the line, as a click does. Every other key
    /// goes on to the menu, which is how the arrows still move between lines and Escape still
    /// closes it.
    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_Space, kVK_ANSI_KeypadEnter:
            choose()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    // MARK: - Drawing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    var isHighlighted: Bool {
        isHovered || enclosingMenuItem?.isHighlighted == true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHighlighted
        if highlighted {
            // Inset and rounded the way the system draws its own menu highlight.
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : .labelColor,
        ]
        // Where the probe for the choice lines put it, beside the system's own lines.
        let textY = ((bounds.height - font.capHeight) / 2 - 3).rounded()
        if let image {
            let size = image.size
            image.draw(
                in: NSRect(
                    x: Self.stateColumnWidth, y: ((bounds.height - size.height) / 2).rounded(), width: size.width,
                    height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSAttributedString(string: title, attributes: attributes)
            .draw(at: NSPoint(x: Self.textLeft(image: image), y: textY))
    }

    /// The column a menu keeps for checkmarks, which its own lines' pictures sit after.
    private static let stateColumnWidth: CGFloat = 23
    private static let rightMargin: CGFloat = 20

    private static func textLeft(image: NSImage?) -> CGFloat {
        stateColumnWidth + (image.map { $0.size.width + 6 } ?? 0)
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    }
}

/// The widget's question, standing where the menu's session lines were.
///
/// A menu draws its own lines, and nothing can be drawn over them; what it can hold is a line
/// with a view of any size. So the lines give way to this one, the rest of the menu stays, and
/// the question is the same view the widget shows, darkened backdrop and all.
///
/// Its buttons take no click of their own: whether a button inside a menu's line can track a
/// press has not been measured, and this line's own release is what a menu is known to
/// deliver — seen again with real clicks on this question (`docs/measurements.md`). The
/// release is handed to the button it lands on.
@MainActor
final class MenuEndAgentQuestionView: NSView {
    let dialog: EndAgentDialog
    private var pressed: EndAgentDialogButton?

    static let width: CGFloat = 300

    init(sessionID: String, sessionName: String?, onCancel: @escaping () -> Void, onEnd: @escaping () -> Void) {
        dialog = EndAgentDialog(
            sessionID: sessionID, sessionName: sessionName, style: .standard, onCancel: onCancel, onEnd: onEnd)
        let height = dialog.heightShowingEverything(atWidth: Self.width)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))
        autoresizingMask = [.width]
        dialog.frame = bounds
        dialog.autoresizingMask = [.width, .height]
        addSubview(dialog)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressed = button(at: event)
        pressed?.isHighlighted = true
    }

    /// A press that started on one button and ended on the other chooses neither. The press
    /// may not arrive at all — only the release was measured — and then the release decides.
    override func mouseUp(with event: NSEvent) {
        let released = button(at: event)
        pressed?.isHighlighted = false
        defer { pressed = nil }
        guard let released, pressed == nil || pressed === released else {
            return
        }
        released.performClick(nil)
    }

    private func button(at event: NSEvent) -> EndAgentDialogButton? {
        let point = dialog.convert(event.locationInWindow, from: nil)
        return [dialog.cancelButton, dialog.endButton].first { button in
            button.convert(button.bounds, to: dialog).contains(point)
        }
    }
}
