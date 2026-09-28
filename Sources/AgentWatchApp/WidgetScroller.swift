import AppKit

/// A slim overlay scroller. AppKit keeps scrolling, tracking and fading; only its drawing changes.
@MainActor
final class WidgetScroller: NSScroller {
    static let thickness: CGFloat = 6
    static let rowClearance: CGFloat = 8

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style)
        -> CGFloat
    {
        thickness
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let ink = NSRect(x: bounds.midX - 2, y: knob.minY, width: 4, height: knob.height)
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: ink, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// Keep the vertical overlay outside the clipped content even during horizontal scrolling.
/// The lane stays reserved while the knob is hidden, so rows never jump when it appears.
@MainActor
final class WidgetScrollView: NSScrollView {
    override func tile() {
        super.tile()
        var viewport = contentView.frame
        viewport.size.width = max(0, viewport.width - WidgetScroller.rowClearance)
        contentView.frame = viewport
    }
}
