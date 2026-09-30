import AppKit

/// Holds whatever the widget is currently showing, plus the things that must outlive a
/// refresh.
///
/// The body — an empty state or a list of sessions — is rebuilt whenever an event arrives.
/// The edge overlay is not: it carries tracking areas, and rebuilding those on every event
/// would drop the pointer's state on the floor exactly while someone is aiming at an edge.
@MainActor
final class HUDContentContainer: NSView {
    private let edges = WidgetEdgeHighlightView()
    private(set) var body: NSView?
    /// Over the body and under the edges, so the widget can still be resized while it is
    /// open and the dialog lays itself out again for the new size.
    private(set) var dialog: EndAgentDialog?
    /// Called when the pointer leaves the widget altogether.
    var onPointerLeft: () -> Void = {}
    /// Whether the pointer is over the widget, which is when its rows hold their places.
    private(set) var isPointerInside = false
    private var exitTracking: NSTrackingArea?

    /// Passed through to the edge overlay, which performs the resize itself.
    var onResizeBegan: () -> Void {
        get { edges.onResizeBegan }
        set { edges.onResizeBegan = newValue }
    }

    var onResizeEnded: () -> Void {
        get { edges.onResizeEnded }
        set { edges.onResizeEnded = newValue }
    }

    var isResizable: Bool {
        get { edges.isResizable }
        set { edges.isResizable = newValue }
    }

    init() {
        super.init(frame: .zero)
        addSubview(edges)
        edges.pinToEdges(of: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// A backstop for the hover card. A row reports the pointer leaving, but a row is
    /// rebuilt whenever an event arrives, and a row that was replaced while the pointer sat
    /// on it never gets to report anything — the card would then stay open over a widget the
    /// pointer had already left. The container outlives every rebuild, so its own exit is
    /// the one report that cannot be missed.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let exitTracking {
            removeTrackingArea(exitTracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        exitTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        pointerLeft()
    }

    /// The entry and the exit, apart from their events, so a test can stage them.
    func pointerEntered() {
        isPointerInside = true
    }

    func pointerLeft() {
        isPointerInside = false
        // The edge highlight goes out here as well as on its own exit. A pointer that leaves
        // the widget fast enough, or leaves while the zones are being re-cut, can skip the
        // strip's own exit; this one cannot be missed.
        edges.clearHighlight()
        onPointerLeft()
    }

    func setBody(_ view: NSView) {
        body?.removeFromSuperview()
        body = view
        // Below the overlay, which never takes a hit and so never gets in the body's way —
        // and below an open dialog, which a rebuilt list must not come up through.
        addSubview(view, positioned: .below, relativeTo: dialog ?? edges)
        view.pinToEdges(of: self)
    }

    /// Fades the dialog in over everything the widget shows. Added transparent and then
    /// faded, never the other way round: added opaque, its first frame is drawn at full
    /// strength before the fade starts, which is a flash.
    func showDialog(_ view: EndAgentDialog) {
        dialog?.removeFromSuperview()
        dialog = view
        view.alphaValue = 0
        addSubview(view, positioned: .below, relativeTo: edges)
        view.pinToEdges(of: self)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EndAgentDialog.fadeDuration
            view.animator().alphaValue = 1
        }
    }

    func hideDialog(animated: Bool = true) {
        guard let dialog else {
            return
        }
        self.dialog = nil
        guard animated else {
            dialog.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EndAgentDialog.fadeDuration
            dialog.animator().alphaValue = 0
        } completionHandler: {
            dialog.removeFromSuperview()
        }
    }
}
