import AppKit
import QuartzCore

/// The counts, drawn inside the status item's button as a grid or as a sphere.
///
/// A view with a layer per cell — or one for the whole sphere — rather than a picture swapped
/// on a timer. Both were measured on a real status item over twenty seconds: the timer at
/// eleven frames a second costs this process 1.95 % of a core, the layers 0.02 % — which is
/// what doing nothing costs. Neither showed above the noise in the window server, whose own
/// load on an idle machine is around 58 % of a core and drifts by more than either variant
/// adds.
///
/// The measurement is only half the reason. A timer redraws a value that has not changed,
/// eleven times a second, for as long as anything is working — against the rule the widget is
/// built on, that a redraw follows a change. It also keeps ticking behind a full-screen
/// window, where nothing is composited at all.
@MainActor
final class MenuBarIconView: NSView {
    /// Told when the item has to change length to hold the drawing, because the status item's
    /// length belongs to whoever owns the item, not to the view inside it.
    var onLengthChange: ((CGFloat) -> Void)?

    private var cells: [MenuBarIconCell] = []
    private var style = MenuBarIconStyle.counts
    /// The sphere's movements as last drawn, so a theme that changes only them still redraws.
    private var sphereMotion = WidgetTheme.active.sphereMotion
    private var drawing: MenuBarIconDrawing?
    /// Kept rather than worked out from the last drawing: by the time a drawing is replaced,
    /// the style it was drawn in may already be the new one.
    private var reportedLength: CGFloat?
    private var cellLayers: [CALayer] = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuBarIconMetrics.barHeight, height: MenuBarIconMetrics.barHeight))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Draws these cells in this style, and says whether it could.
    ///
    /// `false` leaves the caller to put the plain app glyph back: the symbols are the
    /// system's, the deployment floor is older than the machine they were measured on, and an
    /// icon that says less beats an icon that is not there.
    @discardableResult
    func show(
        _ cells: [MenuBarIconCell], as style: MenuBarIconStyle = .counts,
        motion: WidgetTheme.Sphere = WidgetTheme.active.sphereMotion
    ) -> Bool {
        guard cells != self.cells || style != self.style || motion != sphereMotion else {
            return drawing != nil
        }
        let counted = !self.cells.isEmpty && cells.map(\.count) != self.cells.map(\.count)
        self.cells = cells
        self.style = style
        sphereMotion = motion
        guard render() else {
            return false
        }
        if counted && style == .sphere, let seconds = drawing?.swellSeconds {
            cellLayers.forEach { swell($0, over: seconds) }
        }
        return true
    }

    /// How long the status item has to be to hold what is drawn.
    ///
    /// The sphere is one round mark, like the plain glyph, and takes the square item the plain
    /// glyph has — the one width that does not move as the counts do. The grid is as wide as
    /// its numbers and gets the two points `itemPadding` explains.
    var itemLength: CGFloat? {
        guard let drawing else {
            return nil
        }
        return style == .sphere ? NSStatusItem.squareLength : drawing.size.width + MenuBarIconMetrics.itemPadding
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
        let scale = window?.backingScaleFactor ?? 2
        let drawn: MenuBarIconDrawing? =
            switch style {
            case .counts: MenuBarIconRenderer.draw(cells, dark: isDark)
            case .sphere: MenuBarSphereRenderer.draw(cells, dark: isDark, scale: scale, motion: sphereMotion)
            }
        guard let drawing = drawn else {
            return false
        }
        self.drawing = drawing

        cellLayers.forEach { $0.removeFromSuperlayer() }
        cellLayers = drawing.parts.map { part in
            let cell = CALayer()
            cell.contentsScale = scale
            cell.contents = part.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            layer?.addSublayer(cell)
            if part.breathDepth > 0 {
                breathe(cell, downTo: Float(1 - part.breathDepth), period: part.cycle)
            }
            if let fadeImage = part.fadeImage {
                fade(cell, to: fadeImage, period: part.cycle, scale: scale)
            }
            if let glow = part.glow {
                halo(cell, colour: glow, breathing: part.glowBreathes, period: part.glowCycle, in: part.frame.size)
            }
            if part.sways {
                sway(cell, degrees: part.swayDegrees, period: part.swayCycle)
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
        standInForTheButtonsImage()
        if let length = itemLength, length != reportedLength {
            reportedLength = length
            onLengthChange?(length)
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
        standInForTheButtonsImage()
    }

    /// Gives the button an image of its own: transparent, not a template, as large as the
    /// drawing.
    ///
    /// On every screen but the active one the bar does not show this view: it shows a copy of
    /// the item that AppKit draws itself (`NSStatusItemReplicantView`), and it decides how to
    /// blend that copy by the button's image. With no image it takes the content for a
    /// template and adds it to the bar (`plusL`) — right for a white glyph, and it turned the
    /// icon's colours into pastels brighter than anything else on the bar: grey 0.68 came out
    /// 0.84 over a bar of 0.29. With a non-template image the copy is laid over the bar as it
    /// is, dimmed the way the system dims every other item on an inactive bar. Measured on
    /// macOS 15.3.1; the choice is AppKit's and undocumented, so a later release may make it
    /// differently.
    ///
    /// As large as the drawing because the copy may be cut to the image's size, and a grid
    /// wider than its placeholder would lose its right-hand column on the other screen.
    private func standInForTheButtonsImage() {
        guard let button = superview as? NSButton, let size = drawing?.size else {
            return
        }
        guard button.image?.size != size || button.image?.isTemplate != false else {
            return
        }
        button.image = Self.placeholder(size: size)
    }

    /// Made the way the measurement made it — a bitmap filled with clear — rather than as an
    /// image with no pixels behind it, which was never tried.
    static func placeholder(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
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

    /// The drawing is centred in that band rather than pinned to its left edge: the item's
    /// length is set from the drawing's width, but the two are set at different moments and a
    /// stale one must not shift the icon.
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

    /// Anchored to whole breaths on the shared clock (`onTheClock`), so a cell rebuilt halfway
    /// through one — which happens on every count that moves — carries on where the old one
    /// was instead of jumping back to full. Without this the icon twitches at every event.
    private func breathe(_ target: CALayer, downTo dimmest: Float, period: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = dimmest
        target.add(onTheClock(animation, period: period), forKey: Self.breathKey)
    }

    private static let fadeKey = "fade"

    /// The same cell in its second colour, laid over the first and faded in and out: a cell
    /// is a bitmap, and a bitmap's colours cannot be animated, only its opacity.
    private func fade(_ target: CALayer, to image: NSImage, period: TimeInterval, scale: CGFloat) {
        let over = CALayer()
        over.contentsScale = scale
        over.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        over.frame = CGRect(origin: .zero, size: image.size)
        over.opacity = 0
        target.addSublayer(over)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        over.add(onTheClock(animation, period: period), forKey: Self.fadeKey)
    }

    private static let swayKey = "sway"
    private static let swellKey = "swell"

    private func halo(_ target: CALayer, colour: NSColor, breathing: Bool, period: TimeInterval, in size: CGSize) {
        target.shadowColor = colour.cgColor
        target.shadowOffset = .zero
        target.shadowRadius = MenuBarSphereMetrics.glowRadius
        target.shadowOpacity = MenuBarSphereMetrics.glowOpacity
        let side = MenuBarSphereMetrics.diameter
        target.shadowPath = CGPath(
            ellipseIn: CGRect(
                x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side),
            transform: nil
        )
        guard breathing else {
            return
        }
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = MenuBarSphereMetrics.glowBreath.lowerBound
        animation.toValue = MenuBarSphereMetrics.glowBreath.upperBound
        target.add(onTheClock(animation, period: period), forKey: Self.breathKey)
    }

    private func sway(_ target: CALayer, degrees: CGFloat, period: TimeInterval) {
        let reach = degrees * .pi / 180
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = -reach
        animation.toValue = reach
        target.add(onTheClock(animation, period: period), forKey: Self.swayKey)
    }

    /// Once, when a count changes: a little larger and brighter, then back.
    private func swell(_ target: CALayer, over seconds: TimeInterval) {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, MenuBarSphereMetrics.swellScale, 1]
        let brightness = CAKeyframeAnimation(keyPath: "shadowRadius")
        brightness.values = [target.shadowRadius, target.shadowRadius * 2, target.shadowRadius]
        let group = CAAnimationGroup()
        group.animations = [scale, brightness]
        group.duration = seconds
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        target.add(group, forKey: Self.swellKey)
    }

    /// To and fro forever, anchored to whole periods on the shared clock so that a layer rebuilt
    /// halfway carries on where the old one was.
    private func onTheClock(_ animation: CABasicAnimation, period: TimeInterval) -> CABasicAnimation {
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.duration = period / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        let clock = CACurrentMediaTime()
        animation.beginTime = clock - clock.truncatingRemainder(dividingBy: period)
        return animation
    }

    /// Which cells are breathing, for a test that cannot see the screen.
    var breathingCells: [Int] {
        cellLayers.enumerated().compactMap { $0.element.animation(forKey: Self.breathKey) == nil ? nil : $0.offset }
    }

    /// Which cells fade to a second colour, for a test that cannot see the screen.
    var fadingCells: [Int] {
        cellLayers.enumerated().compactMap { index, layer in
            layer.sublayers?.contains { $0.animation(forKey: Self.fadeKey) != nil } == true ? index : nil
        }
    }

    /// Which cells sway, for the test that the theme can stop it.
    var swayingCells: [Int] {
        cellLayers.enumerated().compactMap { $0.element.animation(forKey: Self.swayKey) == nil ? nil : $0.offset }
    }

    /// How long each breath lasts, one full cycle, for the test that the theme sets it.
    var breathPeriods: [CFTimeInterval] {
        cellLayers.compactMap { $0.animation(forKey: Self.breathKey).map { 2 * $0.duration } }
    }

    /// Which cells are swelling, for the test that a changed count swells the sphere.
    var swellingCells: [Int] {
        cellLayers.enumerated().compactMap { $0.element.animation(forKey: Self.swellKey) == nil ? nil : $0.offset }
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

    /// What each cell's layer was handed to show, for the test that it is as sharp as the
    /// screen.
    var cellContents: [Any?] {
        cellLayers.map(\.contents)
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
}
