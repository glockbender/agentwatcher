import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The four rules the menu bar grid is drawn by.
///
/// Every one of them was found by rendering the icon and looking at it, and every one of them
/// looks like an arbitrary constant in the source. So each gets a test that reads the pixels
/// back: what is checked here is what came out, not what the renderer was asked for.
@MainActor
final class MenuBarIconTests: XCTestCase {
    /// A digit is placed on a baseline taken from cap height, not centred in its line box.
    ///
    /// The line box of a 12 pt digit is 15 pt and the digit inside it is 8.5 pt, all the
    /// difference being space for parts of letters a digit does not have. Centring the box in
    /// an 11 pt row leaves room for a 9 pt font and puts the number high in its half of the
    /// bar; centring the cap height fills the row and sits level with the disc beside it.
    func testADigitIsAsTallAsItsCapHeightAndSitsLevelInItsRow() throws {
        let cell = try XCTUnwrap(drawing(needsPerson: 8).parts.first)
        let digit = try XCTUnwrap(ink(of: cell.image, from: digitOnlyLeftEdge))

        let font = NSFont.monospacedDigitSystemFont(ofSize: MenuBarIconMetrics.digitSize, weight: .semibold)
        XCTAssertEqual(digit.height, font.capHeight, accuracy: 1, "an 8 should be its cap height tall")

        // The half that catches centring by the line box: that leaves the ink high, with the
        // descender's empty space below it.
        let above = cell.frame.height - digit.maxY
        XCTAssertEqual(above, digit.minY, accuracy: 1, "the digit sits off-centre in its row")
    }

    /// Each cell is drawn into its own image.
    ///
    /// The gap cut around a digit is a hole punched through everything under it, and a canvas
    /// holding the whole strip meant the hole reached into the next cell — visible as digits
    /// gnawed by a halo that had nothing to do with them.
    func testACellInTheStripIsExactlyTheCellOnItsOwn() throws {
        let grid = drawing(needsPerson: 8, working: 8, done: 8, quiet: 8)
        let strip = grid.composited()

        for (index, part) in grid.parts.enumerated() {
            XCTAssertEqual(
                opaquePixels(of: strip, within: part.frame),
                opaquePixels(of: part.image, within: NSRect(origin: .zero, size: part.frame.size)),
                accuracy: 2,
                "cell \(index) came out of the strip different from how it was drawn"
            )
        }
    }

    /// One glyph slot per column, with every glyph centred in it.
    ///
    /// Drawing each glyph from its own left edge lines up their left sides, so a narrow symbol
    /// sits visibly left of a round one and drags its digit along with it.
    func testANarrowGlyphIsCentredOnTheSameLineAsAWideOne() throws {
        let narrow = MenuBarIconCell(symbol: "play.fill", count: 1, accent: .white, breathDepth: 0)
        let wide = MenuBarIconCell(symbol: "checkmark.circle.fill", count: 1, accent: .white, breathDepth: 0)

        // The same narrow glyph in two columns: one where it is the widest and sets the slot
        // itself, one where the glyph below it is wider. The same symbol both times, so
        // whatever padding it carries inside its own box cancels: what is left is how far the
        // slot moved it.
        let alone = try XCTUnwrap(MenuBarIconRenderer.draw([narrow, wide, narrow, wide], dark: true))
        let beside = try XCTUnwrap(MenuBarIconRenderer.draw([narrow, wide, wide, wide], dark: true))
        let narrowWidth = try slotWidth(of: narrow.symbol)
        let wideWidth = try slotWidth(of: wide.symbol)

        // The left edge of the ink, not its middle. A middle would have to be measured inside
        // a window holding the whole glyph and none of the number, and no such window exists:
        // the glyph reaches higher and lower than the digit does, and where the slot is narrow
        // the number starts further left. The left edge needs no window, because everything to
        // the right of the glyph is the number.
        let withoutWideNeighbour = try XCTUnwrap(ink(of: alone.parts[0].image))
        let withWideNeighbour = try XCTUnwrap(ink(of: beside.parts[0].image))

        // Vacuity guard: with two glyphs of the same width — which is what the shipping four
        // are — centring and not centring give the same answer, and this would prove nothing.
        XCTAssertLessThan(narrowWidth, wideWidth - 1, "both glyphs are the same width; nothing to centre")
        XCTAssertEqual(
            withWideNeighbour.minX - withoutWideNeighbour.minX,
            (wideWidth - narrowWidth) / 2,
            accuracy: 0.3,
            "the narrow glyph did not move to the middle of the slot its neighbour widened"
        )
    }

    /// A gap is cut around the digit, so that it never touches the disc it overlaps.
    ///
    /// Two of the four discs are the colour of the digits, and where a digit met one the two
    /// merged into a single shape.
    func testTheDigitDoesNotTouchTheDiscItOverlaps() throws {
        let cell = try XCTUnwrap(drawing(needsPerson: 8).parts.first)
        // An 8 because its middle is solid: the scan below reads one horizontal line, and a
        // digit with a hole at half height would offer its own counter as the gap.
        let gap = try XCTUnwrap(gapBeforeTheDigit(in: cell.image, y: cell.frame.height / 2))

        XCTAssertGreaterThanOrEqual(gap.width, 1, "the digit is all but touching the disc")

        // The other half: the digit really does sit over the disc, so without the cut the two
        // would meet. A gap between two things that were never going to touch proves nothing.
        let disc = try XCTUnwrap(ink(of: cell.image, to: gap.minX))
        XCTAssertGreaterThan(
            disc.maxX,
            gap.minX - 1,
            "the disc stops well before the digit; the two do not overlap at all"
        )
    }

    /// Three widths, and the item is 16 pt wider than each.
    ///
    /// A column is as wide as the widest number in it, which is the cell above and the cell
    /// below. Measuring one of them clipped a "10" to "1(".
    func testTheGridWidensOnlyWhenAColumnReachesTwoDigits() {
        XCTAssertEqual(drawing(needsPerson: 1, working: 1, done: 1, quiet: 1).size.width, 49)
        XCTAssertEqual(drawing(needsPerson: 12, working: 3, done: 1, quiet: 1).size.width, 57)
        XCTAssertEqual(drawing(needsPerson: 1, working: 1, done: 1, quiet: 10).size.width, 57)
        XCTAssertEqual(drawing(needsPerson: 12, working: 10, done: 11, quiet: 9).size.width, 65)
    }

    /// The deployment floor is older than the machine these symbols were measured on, so a
    /// missing one has to be an answer rather than a crash: the caller puts the plain app
    /// glyph back and the icon says less instead of not being there.
    func testAMissingSymbolLeavesNoDrawingRatherThanHalfOne() {
        let cells = [
            MenuBarIconCell(symbol: "circle.fill", count: 1, accent: .white, breathDepth: 0),
            MenuBarIconCell(symbol: "not.a.symbol.in.any.release", count: 1, accent: .white, breathDepth: 0),
            MenuBarIconCell(symbol: "circle.fill", count: 1, accent: .white, breathDepth: 0),
            MenuBarIconCell(symbol: "circle.fill", count: 1, accent: .white, breathDepth: 0),
        ]

        XCTAssertNil(MenuBarIconRenderer.draw(cells, dark: true))
        XCTAssertFalse(MenuBarIconView().show(cells), "the view claimed it drew a grid it has no symbols for")
    }

    /// Movement means "there is something here", so a zero never breathes.
    func testOnlyTheTwoCellsAPersonCanActOnBreatheAndOnlyWhenTheyHoldSomething() {
        let view = MenuBarIconView()

        view.show(MenuBarIconCell.grid(for: SessionAttentionCounts(needsPerson: 2, working: 3, done: 1, quiet: 1)))
        XCTAssertEqual(view.breathingCells, [0, 1])

        view.show(MenuBarIconCell.grid(for: SessionAttentionCounts(needsPerson: 0, working: 3, done: 0, quiet: 0)))
        XCTAssertEqual(view.breathingCells, [1], "an empty cell is still breathing")

        view.show(MenuBarIconCell.grid(for: SessionAttentionCounts(needsPerson: 0, working: 0, done: 5, quiet: 4)))
        XCTAssertEqual(view.breathingCells, [], "done and idle never breathe")
    }

    /// A count that moves rebuilds the cell, and a rebuilt cell must carry on the breath it
    /// interrupted rather than snapping back to full. Otherwise the icon twitches at every
    /// event, which is most of the day.
    func testACountThatChangesDoesNotRestartTheBreath() throws {
        let view = MenuBarIconView()
        view.show(MenuBarIconCell.grid(for: SessionAttentionCounts(needsPerson: 2, working: 3, done: 0, quiet: 0)))
        let before = try XCTUnwrap(view.breathBeginTimes.first)

        view.show(MenuBarIconCell.grid(for: SessionAttentionCounts(needsPerson: 4, working: 3, done: 0, quiet: 0)))
        let after = try XCTUnwrap(view.breathBeginTimes.first)

        XCTAssertEqual(before, after, accuracy: 0.001, "the breath started over")
    }

    // MARK: - reading the pixels back

    /// Everything to the right of this is the digit alone: the disc is 14 pt wide and the
    /// digit starts 1 pt inside it.
    private let digitOnlyLeftEdge: CGFloat = 15
    private func slotWidth(of symbol: String) throws -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: MenuBarIconMetrics.symbolSize,
            weight: .medium
        )
        let glyph = try XCTUnwrap(
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        )
        return glyph.size.width
    }

    private func drawing(needsPerson: Int = 0, working: Int = 0, done: Int = 0, quiet: Int = 0) -> MenuBarIconDrawing {
        let counts = SessionAttentionCounts(needsPerson: needsPerson, working: working, done: done, quiet: quiet)
        guard let drawn = MenuBarIconRenderer.draw(MenuBarIconCell.grid(for: counts), dark: true) else {
            XCTFail("the system has no symbols for the grid")
            return MenuBarIconDrawing(size: .zero, parts: [])
        }
        return drawn
    }

    /// The box the painted pixels fill, in points, measured from the bottom left.
    private func ink(
        of image: NSImage,
        from left: CGFloat = 0,
        to right: CGFloat = .greatestFiniteMagnitude,
        above bottom: CGFloat = 0
    ) -> NSRect? {
        guard let map = pixels(of: image) else {
            return nil
        }
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for point in map.painted where point.x >= left && point.x < right && point.y >= bottom {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x + map.step)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y + map.step)
        }
        guard minX <= maxX else {
            return nil
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func opaquePixels(of image: NSImage, within frame: NSRect) -> Double {
        guard let map = pixels(of: image) else {
            return 0
        }
        return Double(map.painted.filter { frame.contains(NSPoint(x: $0.x, y: $0.y)) }.count)
    }

    /// The untouched run that separates the digit from the disc, on one horizontal line.
    ///
    /// Found from the right edge inwards — past the digit, across the gap, up to the disc —
    /// because the disc has a mark cut out of its own middle, and a scan from the left would
    /// offer that hole as the answer.
    private func gapBeforeTheDigit(in image: NSImage, y: CGFloat) -> NSRect? {
        guard let map = pixels(of: image) else {
            return nil
        }
        let painted = Set(
            map.painted
                .filter { abs($0.y + map.step / 2 - y) <= map.step }
                .map { Int(($0.x / map.step).rounded(.down)) }
        )
        var column = Int((image.size.width / map.step).rounded(.down)) - 1
        while column >= 0, !painted.contains(column) {
            column -= 1  // the cell is wider than the digit; skip the empty tail
        }
        while column >= 0, painted.contains(column) {
            column -= 1  // and the digit itself
        }
        let right = column + 1
        while column >= 0, !painted.contains(column) {
            column -= 1
        }
        let left = column + 1
        guard right > left, column >= 0 else {
            return nil
        }
        return NSRect(
            x: CGFloat(left) * map.step,
            y: y,
            width: CGFloat(right - left) * map.step,
            height: 0
        )
    }

    /// Painted points in the image's own coordinates, bottom left first, whatever the screen
    /// it was drawn on.
    private func pixels(of image: NSImage) -> (painted: [NSPoint], step: CGFloat)? {
        guard let data = image.tiffRepresentation, let map = NSBitmapImageRep(data: data) else {
            return nil
        }
        let step = image.size.width / CGFloat(map.pixelsWide)
        var painted: [NSPoint] = []
        for row in 0..<map.pixelsHigh {
            // Half-lit, not barely-lit: every edge here is antialiased, and counting the
            // faint fringe as ink adds a pixel all round and makes every measurement below
            // disagree with the geometry it is checking by exactly that much.
            for column in 0..<map.pixelsWide where (map.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.5 {
                painted.append(
                    NSPoint(
                        x: CGFloat(column) * step,
                        y: image.size.height - CGFloat(row + 1) * step
                    )
                )
            }
        }
        return (painted, step)
    }
}
