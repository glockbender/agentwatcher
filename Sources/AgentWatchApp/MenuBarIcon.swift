import AgentWatchCore
import AppKit

/// Every number the grid is drawn from.
///
/// They are here rather than inline because each was settled by looking at the result at
/// actual size, and a reader changing one should see the others it was balanced against.
enum MenuBarIconMetrics {
    /// The menu bar's own height, which two rows of cells divide.
    static let barHeight: CGFloat = 22
    /// 11 pt gives a 14 × 14 disc — a shade under half the bar, so two rows fit with the
    /// digits.
    static let symbolSize: CGFloat = 11
    static let digitSize: CGFloat = 12
    static let gapToDigit: CGFloat = 2
    static let gapBetweenColumns: CGFloat = 7
    /// How far the digit sits back over its disc, tying the pair together into one mark.
    static let overlap: CGFloat = 3
    /// The gap cut around the digit, as a stroke percentage of its own shape. It cannot be
    /// dropped: two of the four discs are the colour of the digits, and without it a "1"
    /// merges into the mark beside it. At 50 % it reads as a dark collar instead of a
    /// hairline.
    static let knockout: CGFloat = 10
    /// What an empty cell is drawn at. A zero has to hold its place without asking to be read.
    static let emptyCellAlpha: CGFloat = 0.4
    /// How much wider than its drawing the status item is made.
    ///
    /// Left to itself `NSStatusItem` adds 16 pt around an image — measured, and constant from
    /// 19 pt of image to 98. That is the right amount for an ordinary 22 pt glyph and far too
    /// much for this one: the grid is wide already, so eight empty points on each side read as
    /// a box drawn round the icon rather than as the gap to the next item. With the length set
    /// here instead, one point a side leaves the spacing between items looking like every
    /// other pair on the bar.
    static let itemPadding: CGFloat = 2
}

/// What the status item draws, in the order the menu offers them.
///
/// There is no style for the app's plain glyph, which counts nothing; the owner took it out.
/// The glyph is still what the item falls back to when the grid's symbols are missing.
enum MenuBarIconStyle: String, CaseIterable {
    /// One sphere, each state shown that holds anything a patch of its colour on it.
    case sphere
    /// A mark and a number for each state shown.
    case counts

    /// Its name where a person chooses it.
    var name: String {
        switch self {
        case .sphere: "Sphere"
        case .counts: "Counts"
        }
    }
}

/// One state as the icon draws it: how many sessions are in it, and how it is drawn — a cell
/// of the grid, or a patch of the sphere.
struct MenuBarIconCell: Equatable {
    let attention: SessionAttention
    let symbol: String
    let count: Int
    let accent: NSColor
    /// How far the cell fades at the bottom of its breath. Zero means it does not breathe.
    let breathDepth: CGFloat
    /// One full breath, or one trip to `fadeTo` and back, in seconds.
    var cycle: TimeInterval = WidgetTheme.markCycle
    /// The colour the cell's mark fades to and back from, when it moves that way instead.
    var fadeTo: NSColor?

    /// One cell per state shown, in the order of `SessionAttention.counted` — which is also
    /// their order of importance, and what `MenuBarIconGrid` places them by.
    ///
    /// How each moves is the theme's (`WidgetTheme.Look.markStyle`); as shipped, only the two a
    /// person can do something about breathe. A cell moves only when it holds something:
    /// movement has to mean "there is something here", and a breathing zero would say the
    /// opposite with the same gesture.
    @MainActor
    static func cells(
        for counts: SessionAttentionCounts,
        showing shown: Set<SessionAttention> = Set(SessionAttention.counted),
        look: WidgetTheme.Look = ThemeInUse.look,
        phases: [SessionPhase: Int] = ThemeInUse.phases
    ) -> [MenuBarIconCell] {
        SessionAttention.counted.filter(shown.contains).map { attention in
            let style = look.markStyle(for: attention, phases: phases)
            return MenuBarIconCell(
                attention: attention,
                symbol: attention.symbolName,
                count: counts.count(of: attention),
                accent: style.color,
                breathDepth: style.motion == .dim ? attention.breathDepth : 0,
                cycle: style.animationCycle,
                fadeTo: style.motion == .gradient && style.gradientColor.srgbHex != style.color.srgbHex
                    ? style.gradientColor : nil
            )
        }
    }
}

extension SessionAttention {
    /// How far this state's cell fades at the bottom of its breath, when it breathes.
    var breathDepth: CGFloat {
        switch self {
        // Deeper than working, at the same rhythm: the one that needs a person has to carry
        // further across a glance without becoming a blink.
        case .needsPerson: 0.65
        case .working, .done, .quiet, .closed: 0.45
        }
    }
}

/// One drawn cell and where it belongs in the strip.
///
/// The strip is kept in pieces rather than as one picture because the two things that read it
/// need different shapes: a still icon composites them, and a breathing one hands each to its
/// own layer. Drawing them separately is not a concession to that — it is required anyway,
/// since the gap cut around a digit acts on a whole canvas and would otherwise eat the
/// neighbouring cell.
struct MenuBarIconPart {
    let image: NSImage
    let frame: NSRect
    var breathDepth: CGFloat = 0
    /// One full breath of the part, or of its fade, in seconds.
    var cycle: TimeInterval = WidgetTheme.markCycle
    /// The same part in the colour it fades to, laid over it and faded in and out.
    var fadeImage: NSImage?
    /// A halo of this colour around the part, for the sphere.
    var glow: NSColor?
    var glowBreathes = false
    var glowCycle: TimeInterval = WidgetTheme.Sphere().haloCycle
    var sways = false
    var swayDegrees: CGFloat = WidgetTheme.Sphere().swayDegrees
    var swayCycle: TimeInterval = WidgetTheme.Sphere().swayCycle
}

/// The whole grid, drawn, in pieces.
struct MenuBarIconDrawing {
    let size: NSSize
    let parts: [MenuBarIconPart]
    /// How long the sphere swells for when a count changes; nil for a drawing that does not.
    var swellSeconds: TimeInterval?

    /// The strip as one picture, at a given point of the breath — `0` for a still icon.
    @MainActor
    func composited(phase: Double = 0) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        for part in parts {
            part.image.draw(
                in: part.frame,
                from: .zero,
                operation: .sourceOver,
                fraction: MenuBarIconDrawing.breathFraction(depth: part.breathDepth, phase: phase)
            )
        }
        image.unlockFocus()
        // Not a template: the system tints a template image with its own colour and would
        // throw the accents away. Worse, `contentTintColor` does not put them back — measured,
        // it paints the whole thing black, which on a dark bar is invisible rather than wrong.
        image.isTemplate = false
        return image
    }

    /// A raised cosine over one breath: still at both ends, quickest in the middle.
    static func breathFraction(depth: CGFloat, phase: Double) -> CGFloat {
        guard depth > 0 else {
            return 1
        }
        return 1 - depth * CGFloat((1 - cos(phase * 2 * .pi)) / 2)
    }
}

/// Where each cell of the grid goes, as columns of indices into the cells, top first.
///
/// Four keep the grid as it shipped. Fewer are stacked two to a column, so two sit one above
/// the other and one sits alone on the bar's middle. Three put the most important — the first
/// — alone on the right and stack the other two beside it. That was chosen by looking at it
/// drawn next to the alternatives: three in the four-cell grid leave a hole that reads as a
/// cell gone missing.
enum MenuBarIconGrid {
    static func columns(count: Int) -> [[Int]] {
        switch count {
        case 1: [[0]]
        case 2: [[0, 1]]
        case 3: [[1, 2], [0]]
        case 4: [[0, 2], [1, 3]]
        default: []
        }
    }
}

/// Draws the grid of counts that stands in for the app's glyph in the menu bar.
@MainActor
enum MenuBarIconRenderer {
    /// `nil` when a symbol is missing, which leaves the caller with the plain app glyph.
    ///
    /// Fail-open, like every other reading this app does of something it does not own: the
    /// deployment floor is older than the machine these symbols were measured on, and an icon
    /// that says less is better than an icon that is not there.
    static func draw(_ cells: [MenuBarIconCell], dark: Bool) -> MenuBarIconDrawing? {
        // An empty list is not a hypothetical — a view repaints itself when the bar turns light
        // or dark, and that can happen before it has ever been given anything to draw.
        let columns = MenuBarIconGrid.columns(count: cells.count)
        guard !columns.isEmpty else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: MenuBarIconMetrics.symbolSize,
            weight: .medium
        )
        let glyphs = cells.compactMap {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }
        guard glyphs.count == cells.count else {
            return nil
        }

        let ink: NSColor = dark ? .white : .black
        let dim = NSColor(white: dark ? 1 : 0, alpha: MenuBarIconMetrics.emptyCellAlpha)
        let font = NSFont.monospacedDigitSystemFont(ofSize: MenuBarIconMetrics.digitSize, weight: .semibold)

        func digitWidth(_ index: Int) -> CGFloat {
            ("\(cells[index].count)" as NSString).size(withAttributes: [.font: font]).width
        }
        let rowHeight = MenuBarIconMetrics.barHeight / 2

        // In the order of `cells`, not of the columns: the view breathes part n for cell n.
        var parts = [MenuBarIconPart?](repeating: nil, count: cells.count)
        var left: CGFloat = 0
        for column in columns {
            // One glyph slot per column, as wide as the widest glyph in it, with every glyph
            // centred inside it. Drawing each glyph from its own left edge lines up their left
            // sides instead of their centres, and a narrow symbol then sits visibly left of a
            // round one and drags its digit along with it.
            let slot = column.map { glyphs[$0].size.width }.max() ?? 0
            // A column is as wide as the widest number in it, which is the pair above and
            // below — measuring one of them is what clipped a "10" to "1(".
            //
            // Rounded up to a whole point, so the next column starts on a pixel boundary. A
            // fraction of a point here is invisible in the layout and costs the cells to the
            // right their edges: every one of them is a bitmap, and a bitmap drawn at half a
            // pixel is resampled into a blur.
            let columnWidth = ceil(
                slot + MenuBarIconMetrics.gapToDigit - MenuBarIconMetrics.overlap
                    + (column.map(digitWidth).max() ?? 0)
            )
            // A cell alone in its column is drawn the bar's height, so that it sits on the
            // bar's middle rather than in the top or bottom half with nothing in the other.
            let height = column.count == 1 ? MenuBarIconMetrics.barHeight : rowHeight
            for (row, index) in column.enumerated() {
                let cell = cells[index]
                let holdsSomething = cell.count > 0
                let text = "\(cell.count)" as NSString
                let textWidth = text.size(withAttributes: [.font: font]).width
                let cellWidth = max(
                    1,
                    ceil(slot + MenuBarIconMetrics.gapToDigit - MenuBarIconMetrics.overlap + textWidth)
                )

                func cellImage(tint: NSColor) -> NSImage {
                    let image = NSImage(size: NSSize(width: cellWidth, height: height))
                    image.lockFocus()
                    drawGlyph(glyphs[index], tint: tint, slot: slot, rowHeight: height)
                    drawDigit(
                        text,
                        font: font,
                        colour: holdsSomething ? ink : dim,
                        x: slot + MenuBarIconMetrics.gapToDigit - MenuBarIconMetrics.overlap,
                        rowHeight: height
                    )
                    image.unlockFocus()
                    return image
                }

                parts[index] = MenuBarIconPart(
                    image: cellImage(tint: holdsSomething ? cell.accent : dim),
                    frame: NSRect(
                        x: left,
                        y: column.count == 1 ? 0 : (row == 0 ? rowHeight : 0),
                        width: cellWidth,
                        height: height
                    ),
                    breathDepth: holdsSomething ? cell.breathDepth : 0,
                    cycle: cell.cycle,
                    fadeImage: holdsSomething ? cell.fadeTo.map { cellImage(tint: $0) } : nil
                )
            }
            left += columnWidth + MenuBarIconMetrics.gapBetweenColumns
        }

        let width = left - MenuBarIconMetrics.gapBetweenColumns
        return MenuBarIconDrawing(
            size: NSSize(width: width, height: MenuBarIconMetrics.barHeight),
            parts: parts.compactMap { $0 }
        )
    }

    /// An SF Symbol is not a shape that can be filled, so it is drawn and then painted
    /// through.
    ///
    /// Painted in, not over: `sourceAtop` keeps the glyph's own coverage and mixes the paint
    /// into its black, so the translucent ink of an empty cell came out as an opaque disc —
    /// grey on a dark bar by luck, solid black on a light one.
    private static func drawGlyph(_ glyph: NSImage, tint: NSColor, slot: CGFloat, rowHeight: CGFloat) {
        let tinted = NSImage(size: glyph.size)
        tinted.lockFocus()
        glyph.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        NSRect(origin: .zero, size: glyph.size).fill(using: .sourceIn)
        tinted.unlockFocus()
        tinted.draw(
            in: NSRect(
                x: (slot - glyph.size.width) / 2,
                y: (rowHeight - glyph.size.height) / 2,
                width: glyph.size.width,
                height: glyph.size.height
            )
        )
    }

    private static func drawDigit(
        _ text: NSString,
        font: NSFont,
        colour: NSColor,
        x: CGFloat,
        rowHeight: CGFloat
    ) {
        // Placed by cap height rather than centred in its line box. A 12 pt digit is 8.5 pt
        // tall and its line box is 15 pt, so centring the box in an 11 pt row leaves room for
        // a 9 pt digit and wastes a third of the height on space above the number.
        let baseline = (rowHeight - font.capHeight) / 2
        let at = NSPoint(x: x, y: baseline + font.descender)
        // The digit's own shape, widened by a negative stroke, cut out of what is underneath.
        // Cutting its bounding box instead takes a rectangular bite out of the disc.
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        text.draw(
            at: at,
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.black,
                .strokeColor: NSColor.black,
                .strokeWidth: -MenuBarIconMetrics.knockout,
            ]
        )
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        text.draw(at: at, withAttributes: [.font: font, .foregroundColor: colour])
    }
}
