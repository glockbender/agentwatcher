import AppKit

/// A checkbox line in a menu that takes a click without closing the menu.
///
/// An ordinary menu line closes the menu on every click, and no flag of its own changes that:
/// `NSMenu.selectionMode = .selectAny` manages checkmarks only, and measured, the menu still
/// closed on each pick. A line whose item has a `view` gets the click itself, and the menu —
/// its whole chain of submenus — stays open. That is what a choice of several lines needs:
/// four states ticked with four clicks, rather than with four trips down two submenus.
///
/// The price is the drawing: a line with a view draws nothing of its own, so the highlight,
/// the checkmark and the greyed look are drawn here, in the system's colours.
///
/// The item keeps an action as well, which calls the same toggle: that is the way in for the
/// keyboard, where Return on a highlighted line is the item's business, not the view's.
@MainActor
final class MenuToggleRowView: NSView {
    let title: String
    let image: NSImage?
    var isOn: Bool {
        didSet {
            setAccessibilityValue(isOn)
            needsDisplay = true
        }
    }
    /// `false` greys the line and turns clicks away, and keeps `isOn` as it was — the choice
    /// is still there for when the line is available again.
    var isAvailable: Bool {
        didSet {
            setAccessibilityEnabled(isAvailable)
            needsDisplay = true
        }
    }
    var onToggle: (() -> Void)?

    /// The height of an ordinary menu line on the machine it was measured on.
    static let height: CGFloat = 22

    init(title: String, image: NSImage? = nil, isOn: Bool, isAvailable: Bool = true) {
        self.title = title
        self.image = image
        self.isOn = isOn
        self.isAvailable = isAvailable
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: Self.height))
        // As wide as the menu makes its widest line, from this width up.
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn)
        setAccessibilityEnabled(isAvailable)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Clicking the line is choosing it, from the keyboard's route or the mouse's.
    func toggle() {
        guard isAvailable else {
            return
        }
        onToggle?()
    }

    override func mouseUp(with event: NSEvent) {
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return isAvailable
    }

    // MARK: - Drawing

    /// The menu tells the line it is highlighted, but not always by redrawing it: the pointer
    /// entering and leaving asks for the redraw that picks the highlight up.
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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isAvailable && enclosingMenuItem?.isHighlighted == true
        if highlighted {
            // Inset and rounded the way the system draws its own menu highlight.
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor =
            !isAvailable ? .disabledControlTextColor : highlighted ? .selectedMenuItemTextColor : .labelColor
        let font = NSFont.menuFont(ofSize: 0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // Where the probe put it, beside the system's own lines, and it was looked at there.
        let textY = (bounds.height - font.capHeight) / 2 - 3
        if isOn {
            NSAttributedString(string: "✓", attributes: attributes).draw(at: NSPoint(x: 10, y: textY))
        }
        var x: CGFloat = 23
        if let image {
            let size = image.size
            image.draw(
                in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: isAvailable ? 1 : 0.35
            )
            x += size.width + 6
        }
        NSAttributedString(string: title, attributes: attributes).draw(at: NSPoint(x: x, y: textY))
    }
}
