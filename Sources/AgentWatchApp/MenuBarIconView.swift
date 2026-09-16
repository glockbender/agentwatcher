import AppKit
import QuartzCore

/// The grid of counts, drawn inside the status item's button.
///
/// A view with a layer per cell rather than a picture swapped on a timer. Both were measured
/// on a real status item over twenty seconds: the timer at eleven frames a second costs this
/// process 1.95 % of a core, the layers 0.02 % — which is what doing nothing costs. Neither
/// showed above the noise in the window server, whose own load on an idle machine is around
/// 58 % of a core and drifts by more than either variant adds.
///
/// The measurement is only half the reason. A timer redraws a value that has not changed,
/// eleven times a second, for as long as anything is working — against the rule the widget is
/// built on, that a redraw follows a change. It also keeps ticking behind a full-screen
/// window, where nothing is composited at all.
@MainActor
final class MenuBarIconView: NSView {
    /// Told when the drawing changes width, because the status item's length belongs to
    /// whoever owns the item, not to the view inside it.
    var onWidthChange: ((CGFloat) -> Void)?

    private var cells: [MenuBarIconCell] = []
    private var drawing: MenuBarIconDrawing?
    private var cellLayers: [CALayer] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuBarIconMetrics.barHeight, height: MenuBarIconMetrics.barHeight))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Draws these four cells, and says whether it could.
    ///
    /// `false` leaves the caller to put the plain app glyph back: the symbols are the
    /// system's, the deployment floor is older than the machine they were measured on, and an
    /// icon that says less beats an icon that is not there.
    @discardableResult
    func show(_ cells: [MenuBarIconCell]) -> Bool {
        guard cells != self.cells else {
            return drawing != nil
        }
        self.cells = cells
        return render()
    }

    /// The button underneath owns the click that opens the menu. Without this the view takes
    /// the press and the menu never appears.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// A view in a layer-backed hierarchy — the status item's button is one — can be handed a
    /// fresh backing layer at any time, and every sublayer and animation goes with the old
    /// one. This is the bug that made the widget's lamp appear to blink only when its row was
    /// rebuilt.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            return
        }
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The cells are bitmaps, drawn at the scale of the screen they were drawn on. Moving
        // to a display of another scale needs them drawn again, not merely scaled.
        render()
    }

    /// The menu bar turns light or dark under the icon, and the icon is not a template image
    /// — nothing but this will repaint it.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    override func layout() {
        super.layout()
        positionLayers()
    }

    @discardableResult
    private func render() -> Bool {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let drawing = MenuBarIconRenderer.draw(cells, dark: isDark) else {
            return false
        }
        let widthChanged = self.drawing?.size.width != drawing.size.width
        self.drawing = drawing

        cellLayers.forEach { $0.removeFromSuperlayer() }
        cellLayers = drawing.parts.map { part in
            let cell = CALayer()
            cell.contentsScale = window?.backingScaleFactor ?? 2
            cell.contents = part.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            layer?.addSublayer(cell)
            if part.breathDepth > 0 {
                breathe(cell, downTo: Float(1 - part.breathDepth))
            }
            return cell
        }
        positionLayers()
        // New layers with new pictures in them are not enough to change what is on screen.
        // Measured: with the counts moving from 0 waiting to 2, every redraw ran and reported
        // success while the bar kept showing the first frame it was ever given, and opening
        // the menu — which makes the button redraw — brought it up to date at once. A status
        // item's window is not on anybody's display cycle while the application is inactive,
        // which is always, so it has to be asked.
        needsDisplay = true
        redrawRequests += 1
        if widthChanged {
            onWidthChange?(drawing.size.width)
        }
        return true
    }

    /// Fills the button, and places the grid on the bar rather than on the button.
    ///
    /// Called instead of setting the frame from outside, because the frame is only half of it:
    /// the layers have to be placed again afterwards, and waiting for AppKit's own layout pass
    /// leaves the grid at wherever the view's first, sizeless bounds put it.
    func fill(_ button: NSView) {
        frame = button.bounds
        autoresizingMask = [.width, .height]
        positionLayers()
    }

    /// The band the status bar actually gave this item.
    ///
    /// Not `bounds`, because the button is not always its own slot: measured, it is 22 pt tall
    /// at launch and 28 pt tall once the item has been rebuilt — hanging 2.5 pt below the bar
    /// and 3.5 above it — so a grid centred in the button sits off the bar's centre, and moves
    /// the moment the counts are switched off and on again. The view holding the button keeps
    /// the bar's height whatever the button does.
    private var barSlot: NSRect {
        guard let container = superview?.superview else {
            return bounds
        }
        return convert(container.bounds, from: container)
    }

    /// The grid is centred in that band rather than pinned to its left edge: the item's length
    /// is set from the drawing's width, but the two are set at different moments and a stale
    /// one must not shift the icon.
    private func positionLayers() {
        guard let drawing else {
            return
        }
        let slot = barSlot
        // Snapped to whole pixels rather than whole points: the slot's own origin lands on a
        // half point when the button is the taller of its two sizes, and rounding that to a
        // point would move the grid half a point off the bar's centre to buy a crispness it
        // already has.
        let left = snapped(slot.minX + (slot.width - drawing.size.width) / 2)
        let bottom = snapped(slot.minY + (slot.height - drawing.size.height) / 2)
        CATransaction.begin()
        // Position is set from layout, which can run inside an implicit animation. A grid that
        // slides into place on every redraw is not what any of this is for.
        CATransaction.setDisableActions(true)
        for (layer, part) in zip(cellLayers, drawing.parts) {
            layer.frame = part.frame.offsetBy(dx: left, dy: bottom)
        }
        CATransaction.commit()
    }

    private func snapped(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    private static let breathKey = "breath"

    private func breathe(_ target: CALayer, downTo dimmest: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = dimmest
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.duration = MenuBarIconMetrics.breathSeconds / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        // Anchored to whole breaths on the shared clock, so a cell rebuilt halfway through one
        // — which happens on every count that moves — carries on where the old one was instead
        // of jumping back to full. Without this the icon twitches at every event.
        let clock = CACurrentMediaTime()
        animation.beginTime = clock - clock.truncatingRemainder(dividingBy: MenuBarIconMetrics.breathSeconds)
        target.add(animation, forKey: Self.breathKey)
    }

    /// Which cells are breathing, for a test that cannot see the screen.
    var breathingCells: [Int] {
        cellLayers.enumerated().compactMap { $0.element.animation(forKey: Self.breathKey) == nil ? nil : $0.offset }
    }

    /// How many times the view has asked to be shown again.
    ///
    /// Counted rather than read back from `needsDisplay`: on a layer-backed view AppKit turns
    /// the request into layer invalidation, and the flag reads false again immediately — tried
    /// in a window ordered on screen, and it still does. The flag is not an honest answer to
    /// "did this ask to be redrawn", so the test asks this instead.
    private(set) var redrawRequests = 0

    /// Where the cells ended up, for a test that cannot see the bar.
    var cellFrames: [NSRect] {
        cellLayers.map { $0.frame }
    }

    /// Where each breath was anchored, for the test that a rebuilt cell carries on rather
    /// than starting over.
    var breathBeginTimes: [CFTimeInterval] {
        cellLayers.compactMap { $0.animation(forKey: Self.breathKey)?.beginTime }
    }

    /// What the render tree is showing right now — the proof that an animation is running and
    /// not merely attached.
    var presentedOpacities: [Float] {
        cellLayers.map { $0.presentation()?.opacity ?? 1 }
    }

    var drawnWidth: CGFloat? {
        drawing?.size.width
    }
}
