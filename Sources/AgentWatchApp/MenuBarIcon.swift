import AgentWatchCore
import AppKit

/// The four colours of the menu bar grid.
///
/// Fixed numbers rather than `NSColor.systemOrange` and friends, and not a setting either.
/// Two reasons, both measured. The menu bar is not the widget's canvas: the app paints the
/// widget's background and knows which of ten it is, while the bar belongs to the system and
/// may be dark, light or a photograph — an accent that reads on one can vanish on another, so
/// these four were chosen by looking at all of them. And a scheme a person can edit is how
/// the widget ended up with three phases grey by default (ADR-0003); here there is nothing to
/// edit, and the mark cut out of each disc carries the state when the colour does not.
enum MenuBarIconPalette {
    /// systemOrange as it resolves for a dark appearance.
    static let needsPerson = NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
    /// Within one unit of systemBlue for a dark appearance.
    static let working = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1)
    /// Lighter than systemGreen for a dark appearance, which is the point: it reads on a
    /// light bar as well, where the system's own green goes muddy.
    static let done = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    /// Deliberately not a hue. This is the one cell nobody should look at, and any colour
    /// would have made it compete with the other three.
    static let quiet = NSColor(white: 0.62, alpha: 1)
}

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
    /// One breath, the same length as the widget's lamp so the two read as one app.
    static let breathSeconds: TimeInterval = 1.4
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

/// One cell of the grid: a state, how many sessions are in it, and how it is drawn.
struct MenuBarIconCell: Equatable {
    let symbol: String
    let count: Int
    let accent: NSColor
    /// How far the cell fades at the bottom of its breath. Zero means it does not breathe.
    let breathDepth: CGFloat

    /// The four cells, in reading order: top row first, then bottom.
    ///
    /// Only the two a person can do something about breathe, and only when they hold
    /// something. Movement has to mean "there is something here"; a breathing zero would say
    /// the opposite with the same gesture.
    static func grid(for counts: SessionAttentionCounts) -> [MenuBarIconCell] {
        [
            MenuBarIconCell(
                symbol: "exclamationmark.circle.fill",
                count: counts.needsPerson,
                accent: MenuBarIconPalette.needsPerson,
                // Deeper than working, at the same rhythm: the one that needs a person has to
                // carry further across a glance without becoming a blink.
                breathDepth: 0.65
            ),
            MenuBarIconCell(
                symbol: "play.circle.fill",
                count: counts.working,
                accent: MenuBarIconPalette.working,
                breathDepth: 0.45
            ),
            MenuBarIconCell(
                symbol: "checkmark.circle.fill",
                count: counts.done,
                accent: MenuBarIconPalette.done,
                breathDepth: 0
            ),
            MenuBarIconCell(
                symbol: "minus.circle.fill",
                count: counts.quiet,
                accent: MenuBarIconPalette.quiet,
                breathDepth: 0
            ),
        ]
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
    let breathDepth: CGFloat
}

/// The whole grid, drawn, in pieces.
struct MenuBarIconDrawing {
    let size: NSSize
    let parts: [MenuBarIconPart]

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

/// Draws the 2 × 2 grid of counts that stands in for the app's glyph in the menu bar.
@MainActor
enum MenuBarIconRenderer {
    /// `nil` when a symbol is missing, which leaves the caller with the plain app glyph.
    ///
    /// Fail-open, like every other reading this app does of something it does not own: the
    /// deployment floor is older than the machine these symbols were measured on, and an icon
    /// that says less is better than an icon that is not there.
    static func draw(_ cells: [MenuBarIconCell], dark: Bool) -> MenuBarIconDrawing? {
        // Four, because everything below is written in columns and rows: a cell reaches for the
        // one two places along to find out how wide its column has to be. An empty list is not
        // a hypothetical — a view repaints itself when the bar turns light or dark, and that
        // can happen before it has ever been given anything to draw.
        guard cells.count == 4 else {
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
        // One glyph slot per column, as wide as the widest glyph in it, with every glyph
        // centred inside it. Drawing each glyph from its own left edge lines up their left
        // sides instead of their centres, and a narrow symbol then sits visibly left of a
        // round one and drags its digit along with it.
        let glyphSlot = (0..<2).map { max(glyphs[$0].size.width, glyphs[$0 + 2].size.width) }
        // A column is as wide as the widest number in it, which is the pair above and below —
        // measuring one of them is what clipped a "10" to "1(".
        //
        // Rounded up to a whole point, so the second column starts on a pixel boundary. A
        // fraction of a point here is invisible in the layout and costs the right-hand cells
        // their edges: every one of them is a bitmap, and a bitmap drawn at half a pixel is
        // resampled into a blur.
        let columnWidth = (0..<2).map { column in
            ceil(
                glyphSlot[column] + MenuBarIconMetrics.gapToDigit - MenuBarIconMetrics.overlap
                    + max(digitWidth(column), digitWidth(column + 2))
            )
        }
        let rowHeight = MenuBarIconMetrics.barHeight / 2

        var parts: [MenuBarIconPart] = []
        for (index, cell) in cells.enumerated() {
            let column = index % 2
            let row = index / 2
            let glyph = glyphs[index]
            let holdsSomething = cell.count > 0
            let slot = glyphSlot[column]
            let text = "\(cell.count)" as NSString
            let textWidth = text.size(withAttributes: [.font: font]).width
            let cellWidth = max(
                1,
                ceil(slot + MenuBarIconMetrics.gapToDigit - MenuBarIconMetrics.overlap + textWidth)
            )

            let cellImage = NSImage(size: NSSize(width: cellWidth, height: rowHeight))
            cellImage.lockFocus()
            drawGlyph(glyph, tint: holdsSomething ? cell.accent : dim, slot: slot, rowHeight: rowHeight)
            drawDigit(
                text,
                font: font,
                colour: holdsSomething ? ink : dim,
                x: slot + MenuBarIconMetrics.gapToDigit - MenuBarIconMetrics.overlap,
                rowHeight: rowHeight
            )
            cellImage.unlockFocus()

            parts.append(
                MenuBarIconPart(
                    image: cellImage,
                    frame: NSRect(
                        x: column == 0 ? 0 : columnWidth[0] + MenuBarIconMetrics.gapBetweenColumns,
                        y: row == 0 ? rowHeight : 0,
                        width: cellWidth,
                        height: rowHeight
                    ),
                    breathDepth: holdsSomething ? cell.breathDepth : 0
                )
            )
        }

        let width = columnWidth[0] + MenuBarIconMetrics.gapBetweenColumns + columnWidth[1]
        return MenuBarIconDrawing(
            size: NSSize(width: width, height: MenuBarIconMetrics.barHeight),
            parts: parts
        )
    }

    /// An SF Symbol is not a shape that can be filled, so it is drawn and then painted
    /// through.
    private static func drawGlyph(_ glyph: NSImage, tint: NSColor, slot: CGFloat, rowHeight: CGFloat) {
        let tinted = NSImage(size: glyph.size)
        tinted.lockFocus()
        glyph.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        NSRect(origin: .zero, size: glyph.size).fill(using: .sourceAtop)
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
