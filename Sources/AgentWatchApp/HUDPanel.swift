import AppKit

/// The widget's window.
///
/// A panel rather than a window, and one that refuses both the keyboard and main status: a
/// click on the widget must never take the focus away from whatever is being worked in.
/// Everything that follows from that refusal — the drawn edge highlight, the hover card being
/// a window of its own — is in `WidgetEdgeHighlightView` and `SessionHoverCard`.

@MainActor
final class HUDPanel: NSPanel {
    private static let highlightDuration: CFTimeInterval = 5
    private var highlightLayer: CAShapeLayer?
    private var highlightOverlay: HUDHighlightOverlayView?
    private var isHighlightRetryScheduled = false

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Has to be called again after every style-mask change, not only at creation: the frame
    /// view AppKit builds for the new mask brings its own buttons, already visible.
    func hideStandardButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    func highlight() {
        let outline = CAShapeLayer()
        outline.strokeColor = NSColor.systemOrange.cgColor
        outline.fillColor = NSColor.clear.cgColor
        outline.lineWidth = 3
        outline.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        highlightLayer?.removeFromSuperlayer()
        highlightLayer = outline
        updateHighlightOverlay()

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.2
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatDuration = Self.highlightDuration
        outline.add(pulse, forKey: "agent-watch-highlight")

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDuration) { [weak self, weak outline] in
            guard self?.highlightLayer === outline else {
                return
            }
            outline?.removeFromSuperlayer()
            self?.highlightOverlay?.removeFromSuperview()
            self?.highlightOverlay = nil
            self?.highlightLayer = nil
        }
    }

    func updateHighlightOverlay() {
        guard let contentView, let highlightLayer else {
            return
        }
        contentView.layoutSubtreeIfNeeded()
        guard hasUsableHighlightGeometry(contentView.bounds) else {
            scheduleHighlightRetry()
            return
        }

        let overlay: HUDHighlightOverlayView
        if let existing = highlightOverlay, existing.superview === contentView {
            overlay = existing
        } else {
            highlightOverlay?.removeFromSuperview()
            let newOverlay = HUDHighlightOverlayView(frame: contentView.bounds)
            newOverlay.autoresizingMask = [.width, .height]
            contentView.addSubview(newOverlay, positioned: .above, relativeTo: nil)
            highlightOverlay = newOverlay
            overlay = newOverlay
        }
        overlay.frame = contentView.bounds
        overlay.layoutSubtreeIfNeeded()
        guard hasUsableHighlightGeometry(overlay.bounds) else {
            scheduleHighlightRetry()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.frame = overlay.bounds.insetBy(dx: 2, dy: 2)
        highlightLayer.path = CGPath(
            roundedRect: highlightLayer.bounds,
            cornerWidth: WidgetStyle.windowCornerRadius,
            cornerHeight: WidgetStyle.windowCornerRadius,
            transform: nil
        )
        overlay.layer?.addSublayer(highlightLayer)
        CATransaction.commit()
    }

    private func hasUsableHighlightGeometry(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private func scheduleHighlightRetry() {
        guard !isHighlightRetryScheduled else {
            return
        }
        isHighlightRetryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isHighlightRetryScheduled = false
            self.updateHighlightOverlay()
        }
    }
}

@MainActor
final class HUDHighlightOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
