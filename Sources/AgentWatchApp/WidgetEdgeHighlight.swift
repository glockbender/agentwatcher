import AppKit

/// Lights up the border strip the pointer is over, so a drag that resizes the widget can be
/// told from a drag that moves it.
///
/// This is drawn rather than shown as a resize cursor, and the reason is a limitation of
/// macOS rather than a preference. A resize cursor appears only over the window that holds
/// the keyboard focus. Measured on four window configurations, all in an application that
/// was never active: an ordinary window shows one the moment it takes focus and never
/// before; a panel built like this widget shows none at all; a panel allowed to take focus
/// shows one only after a click. `NSCursor.set()` from the background changes the
/// application's own cursor — `NSCursor.current` follows it — and the screen ignores it.
///
/// The widget refuses focus on purpose, so that clicking it never takes the keyboard away
/// from the window being worked in. Refusing focus and showing a resize cursor cannot both
/// be had, and the focus is worth more.
///
/// What the background *does* receive is `mouseEntered`, `mouseMoved` and `mouseExited`
/// through `.activeAlways` tracking areas — measured at 371 movements in one session behind
/// another application — which is enough to draw this.
@MainActor
final class WidgetEdgeHighlightView: NSView {
    /// How wide the resize strip is. Matches what the window server itself accepts for a
    /// resize drag closely enough that the highlight never promises something that then fails.
    static let edgeThickness: CGFloat = 6
    /// How thick the lit band is. Thinner than the strip it marks: the strip is a target, the
    /// band is a hint, and a 6-point slab of colour reads as a border the widget does not have.
    static let highlightThickness: CGFloat = 3
    /// How far a corner's highlight runs along each of its two sides. A corner's own zone is
    /// six points square, which lit on its own looks like a speck rather than a corner.
    static let cornerRun: CGFloat = 26
    /// How deep into the widget a band reaches. Wider than the band itself on purpose: the
    /// band is a stroke along the widget's rounded outline, and at a corner that stroke
    /// curves inward by the corner radius. A window only as deep as the stroke would cut the
    /// curve off and leave the corner looking broken in two.
    static let bandDepth: CGFloat = WidgetStyle.windowCornerRadius + highlightThickness

    var isResizable = true {
        didSet {
            guard isResizable != oldValue else {
                return
            }
            if !isResizable {
                // The drag goes with it. A locked edge that kept a drag alive would go on
                // resizing the widget the lock was just put on.
                drag = nil
                highlightedEdge = nil
            }
            updateTrackingAreas()
        }
    }

    /// The strip under the pointer, or `nil` when the pointer is elsewhere.
    private(set) var highlightedEdge: Edge? {
        didSet {
            guard highlightedEdge != oldValue else {
                return
            }
            needsDisplay = true
        }
    }

    /// The bounds the current zones were cut for.
    private var zonedBounds: NSRect = .zero

    /// Takes a click only where it lights up, and nowhere else.
    ///
    /// The lit strip has to be the strip that resizes, or the widget promises one thing and
    /// does another. Left to itself it did exactly that: the window server accepts a resize
    /// drag just *outside* the frame, while a press inside the frame reaches the window
    /// background and moves the widget instead — so the band marked the region that moved it.
    /// Taking the press here puts the two back together, and the middle of the widget is left
    /// alone so that dragging it still moves the widget.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isResizable, let superview else {
            return nil
        }
        let local = convert(point, from: superview)
        return Self.zone(at: local, in: bounds) == nil ? nil : self
    }

    /// The zones are fixed rectangles, so they have to be re-cut when the widget changes
    /// size — and the widget changes size the moment the first session arrives, growing from
    /// the empty state to a list. Measured: after that growth the areas still described the
    /// old 340×56 widget while its border had moved to 520×300, so the pointer crossed the
    /// real edge without entering any of them. Nothing else re-cuts them; AppKit calls
    /// `updateTrackingAreas` for a hierarchy change, not for a window the user drags wider.
    ///
    /// Only on a real change: rebuilding the areas takes the pointer out of whichever one it
    /// is in, and a layout pass runs far more often than a resize.
    override func layout() {
        super.layout()
        guard bounds != zonedBounds else {
            return
        }
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Before the areas go, and not after: removing one sends no exit, so a widget that
        // resizes while the pointer rests on an edge would leave a band lit with nothing
        // left to put it out.
        //
        // Unless the widget is being resized by this very strip. A drag changes the size on
        // every frame and so re-cuts the zones on every frame, which put the band out on the
        // first frame of the drag it had just promised. A drag also sends `mouseDragged`
        // rather than `mouseMoved`, so nothing would have lit it again until the drag ended.
        highlightedEdge = drag?.edge
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        zonedBounds = bounds
        guard isResizable else {
            return
        }
        // One area per zone, and `.mouseMoved` on each, so that sliding from one strip into
        // its neighbour moves the highlight rather than leaving it on the strip behind.
        for rect in Self.edgeZones(in: bounds).map(\.rect) {
            addTrackingArea(
                NSTrackingArea(
                    rect: rect,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                    owner: self
                ))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        highlight(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        highlight(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        highlight(for: event)
    }

    /// Asked of the point rather than of which area reported it: the strips touch each other,
    /// and leaving one for its neighbour arrives as an exit that would otherwise put out a
    /// band the pointer is still on.
    private func highlight(for event: NSEvent) {
        highlight(at: convert(event.locationInWindow, from: nil))
    }

    func highlight(at point: NSPoint) {
        guard isResizable else {
            highlightedEdge = nil
            return
        }
        highlightedEdge = Self.zone(at: point, in: bounds)?.edge
    }

    /// Called by the container as well, which is the one view that cannot miss the pointer
    /// leaving the widget altogether.
    ///
    /// Silent during a drag. Dragging an edge outward takes the pointer off the widget, and
    /// the strip is captured for the whole drag whether or not the pointer is still over it.
    func clearHighlight() {
        guard drag == nil else {
            return
        }
        highlightedEdge = nil
    }

    // MARK: - Resizing

    /// Reported so the widget can stop sizing itself to its session count while a drag is in
    /// progress, and can save the size the drag ended on.
    var onResizeBegan: () -> Void = {}
    var onResizeEnded: () -> Void = {}

    private struct ResizeDrag {
        let edge: Edge
        let initialFrame: NSRect
        /// In screen coordinates, which is the one frame of reference that does not move
        /// while the window it belongs to is being resized under the pointer.
        let initialPointer: NSPoint
    }

    private var drag: ResizeDrag?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isResizable, let zone = Self.zone(at: point, in: bounds), let window else {
            super.mouseDown(with: event)
            return
        }
        drag = ResizeDrag(edge: zone.edge, initialFrame: window.frame, initialPointer: NSEvent.mouseLocation)
        highlightedEdge = zone.edge
        onResizeBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window else {
            super.mouseDragged(with: event)
            return
        }
        let pointer = NSEvent.mouseLocation
        let frame = Self.resizedFrame(
            from: drag.initialFrame,
            edge: drag.edge,
            delta: NSPoint(x: pointer.x - drag.initialPointer.x, y: pointer.y - drag.initialPointer.y),
            minimum: window.minSize
        )
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else {
            super.mouseUp(with: event)
            return
        }
        drag = nil
        onResizeEnded()
    }

    /// Where the window lands for a drag of `delta` on one of its edges.
    ///
    /// Screen coordinates, so `y` grows upward: dragging the bottom edge down is a negative
    /// `dy` that has to *lower* the origin and *raise* the height. The minimum is applied per
    /// axis by holding the opposite edge still, which is what stops a window from walking
    /// across the screen once it can shrink no further.
    static func resizedFrame(from initial: NSRect, edge: Edge, delta: NSPoint, minimum: NSSize) -> NSRect {
        var frame = initial
        switch edge {
        case .left, .topLeft, .bottomLeft:
            frame.size.width = max(minimum.width, initial.width - delta.x)
            frame.origin.x = initial.maxX - frame.width
        case .right, .topRight, .bottomRight:
            frame.size.width = max(minimum.width, initial.width + delta.x)
        case .top, .bottom:
            break
        }
        switch edge {
        case .bottom, .bottomLeft, .bottomRight:
            frame.size.height = max(minimum.height, initial.height - delta.y)
            frame.origin.y = initial.maxY - frame.height
        case .top, .topLeft, .topRight:
            frame.size.height = max(minimum.height, initial.height + delta.y)
        case .left, .right:
            break
        }
        return frame
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let highlightedEdge else {
            return
        }
        // Drawn as a stroke along the widget's own outline rather than as plain rectangles,
        // so that a corner is traced by the same curve the widget is drawn with. Straight
        // bands met at a right angle inside a rounded corner and read as two separate marks.
        let inset = Self.highlightThickness / 2
        let outline = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: max(0, WidgetStyle.windowCornerRadius - inset),
            yRadius: max(0, WidgetStyle.windowCornerRadius - inset)
        )
        outline.lineWidth = Self.highlightThickness

        // The window decides how much of that outline is lit: one side, or the two short runs
        // that meet at a corner.
        let window = NSBezierPath()
        for rect in Self.highlightRects(for: highlightedEdge, in: bounds) {
            window.appendRect(rect)
        }

        NSGraphicsContext.saveGraphicsState()
        window.addClip()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Which parts of the widget's outline are lit: one whole side, or the two short runs
    /// that meet at a corner. These are windows onto the outline, not the painted band — the
    /// band is a stroke of `highlightThickness` drawn through them.
    ///
    /// Kept free of any view so the geometry can be checked without building a window.
    static func highlightRects(
        for edge: Edge,
        in bounds: NSRect,
        thickness: CGFloat = bandDepth,
        cornerRun: CGFloat = cornerRun
    ) -> [NSRect] {
        let run = min(cornerRun, min(bounds.width, bounds.height))
        let left = NSRect(x: bounds.minX, y: bounds.minY, width: thickness, height: bounds.height)
        let right = NSRect(x: bounds.maxX - thickness, y: bounds.minY, width: thickness, height: bounds.height)
        let bottom = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: thickness)
        let top = NSRect(x: bounds.minX, y: bounds.maxY - thickness, width: bounds.width, height: thickness)

        func stub(_ side: NSRect, alongX: Bool, fromStart: Bool) -> NSRect {
            if alongX {
                return NSRect(
                    x: fromStart ? side.minX : side.maxX - run, y: side.minY, width: run, height: side.height)
            }
            return NSRect(
                x: side.minX, y: fromStart ? side.minY : side.maxY - run, width: side.width, height: run)
        }

        // Unflipped coordinates: `y == 0` is the bottom of the widget.
        return switch edge {
        case .left: [left]
        case .right: [right]
        case .bottom: [bottom]
        case .top: [top]
        case .bottomLeft:
            [stub(left, alongX: false, fromStart: true), stub(bottom, alongX: true, fromStart: true)]
        case .bottomRight:
            [stub(right, alongX: false, fromStart: true), stub(bottom, alongX: true, fromStart: false)]
        case .topLeft:
            [stub(left, alongX: false, fromStart: false), stub(top, alongX: true, fromStart: true)]
        case .topRight:
            [stub(right, alongX: false, fromStart: false), stub(top, alongX: true, fromStart: false)]
        }
    }

    struct EdgeZone {
        let rect: NSRect
        let edge: Edge
    }

    enum Edge {
        case left, right, bottom, top
        case bottomLeft, bottomRight, topLeft, topRight
    }

    /// Which strip a point falls in, or `nil` for the middle of the widget.
    static func zone(at point: NSPoint, in bounds: NSRect) -> EdgeZone? {
        edgeZones(in: bounds).first { $0.rect.contains(point) }
    }

    /// Corners first: they overlap the edges, and a corner resizes in two directions, which
    /// is the more specific answer where both apply.
    ///
    /// Coordinates are unflipped, so `y == 0` is the bottom of the widget.
    static func edgeZones(in bounds: NSRect, thickness: CGFloat = edgeThickness) -> [EdgeZone] {
        guard bounds.width > 2 * thickness, bounds.height > 2 * thickness else {
            return []
        }
        let inner = bounds.insetBy(dx: thickness, dy: thickness)
        return [
            EdgeZone(
                rect: NSRect(x: bounds.minX, y: bounds.minY, width: thickness, height: thickness), edge: .bottomLeft),
            EdgeZone(
                rect: NSRect(x: inner.maxX, y: bounds.minY, width: thickness, height: thickness), edge: .bottomRight),
            EdgeZone(rect: NSRect(x: bounds.minX, y: inner.maxY, width: thickness, height: thickness), edge: .topLeft),
            EdgeZone(rect: NSRect(x: inner.maxX, y: inner.maxY, width: thickness, height: thickness), edge: .topRight),
            EdgeZone(rect: NSRect(x: bounds.minX, y: inner.minY, width: thickness, height: inner.height), edge: .left),
            EdgeZone(rect: NSRect(x: inner.maxX, y: inner.minY, width: thickness, height: inner.height), edge: .right),
            EdgeZone(rect: NSRect(x: inner.minX, y: bounds.minY, width: inner.width, height: thickness), edge: .bottom),
            EdgeZone(rect: NSRect(x: inner.minX, y: inner.maxY, width: inner.width, height: thickness), edge: .top),
        ]
    }
}
