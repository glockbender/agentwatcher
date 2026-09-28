import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The icon with fewer than four states, the pie, and what either asks of the status item.
///
/// Each layout below was chosen by drawing it beside the alternatives, so each is pinned by
/// where its parts end up rather than by the arithmetic that put them there.
@MainActor
final class MenuBarIconStylesTests: XCTestCase {
    private let row = MenuBarIconMetrics.barHeight / 2

    // MARK: - the grid with fewer states

    /// Four keep the grid as it shipped: needs you and working on top, done and idle below.
    func testFourStatesKeepTheGridAsItShipped() throws {
        let frames = try grid(showing: Set(SessionAttention.counted)).parts.map(\.frame)

        XCTAssertEqual(frames.map(\.minY), [row, row, 0, 0])
        XCTAssertEqual(frames[0].minX, 0)
        XCTAssertEqual(frames[2].minX, 0)
        XCTAssertGreaterThan(frames[1].minX, frames[0].maxX)
        XCTAssertEqual(frames[1].minX, frames[3].minX)
    }

    /// Two stand one above the other, the more important on top, in one column.
    func testTwoStatesStandOneAboveTheOther() throws {
        let frames = try grid(showing: [.needsPerson, .working]).parts.map(\.frame)

        XCTAssertEqual(frames.map(\.minX), [0, 0])
        XCTAssertEqual(frames.map(\.minY), [row, 0], "needs you is not on top")
    }

    /// Three put the most important alone on the right, on the bar's middle, and stack the
    /// other two beside it.
    func testThreeStatesPutTheMostImportantAloneOnTheRight() throws {
        let frames = try grid(showing: [.needsPerson, .working, .done]).parts.map(\.frame)

        XCTAssertEqual(frames[0].minY, 0)
        XCTAssertEqual(frames[0].height, MenuBarIconMetrics.barHeight, "the lone cell is not the bar's height")
        XCTAssertGreaterThan(frames[0].minX, max(frames[1].maxX, frames[2].maxX), "needs you is not on the right")
        XCTAssertEqual(frames[1].minX, frames[2].minX)
        XCTAssertEqual([frames[1].minY, frames[2].minY], [row, 0])
    }

    /// The mirrored case: without needs you, the most important left is working, and it is
    /// working that stands alone — the rule is the order, not the state.
    func testWithoutNeedsYouTheNextMostImportantStandsAlone() throws {
        let frames = try grid(showing: [.working, .done, .quiet]).parts.map(\.frame)

        XCTAssertEqual(frames[0].height, MenuBarIconMetrics.barHeight)
        XCTAssertGreaterThan(frames[0].minX, frames[1].maxX, "working is not on the right")
        XCTAssertEqual([frames[1].minY, frames[2].minY], [row, 0])
    }

    /// One cell sits on the bar's middle, not in the top half with nothing below it.
    func testOneStateSitsOnTheBarsMiddle() throws {
        let part = try XCTUnwrap(grid(showing: [.done]).parts.first)
        let glyph = try XCTUnwrap(ink(of: part.image, leftOf: 14))

        XCTAssertEqual(part.frame.height, MenuBarIconMetrics.barHeight)
        XCTAssertEqual(glyph.midY, MenuBarIconMetrics.barHeight / 2, accuracy: 0.5, "the mark is off the bar's middle")
    }

    /// A column fewer is a column narrower, and the item follows.
    func testTheGridIsAsWideAsItsColumns() throws {
        let widths = try [
            [SessionAttention.needsPerson],
            [.needsPerson, .working],
            [.needsPerson, .working, .done],
            SessionAttention.counted,
        ].map { try grid(showing: Set($0)).size.width }

        XCTAssertEqual(widths, [21, 21, 49, 49])
    }

    /// An empty cell is drawn in translucent ink on either bar. Painting the ink over the
    /// glyph instead of into it kept the glyph's own black under it, which on a light bar
    /// came out as a solid black disc — the loudest cell in the grid for the one that holds
    /// nothing.
    func testAnEmptyCellIsTranslucentOnEitherBar() throws {
        for dark in [true, false] {
            let empty = try XCTUnwrap(
                MenuBarIconRenderer.draw(cells(showing: [.done], done: 0), dark: dark)?.parts.first
            )
            let held = try XCTUnwrap(
                MenuBarIconRenderer.draw(cells(showing: [.done], done: 3), dark: dark)?.parts.first
            )

            XCTAssertEqual(
                try strongestAlpha(in: empty.image, leftOf: 14),
                MenuBarIconMetrics.emptyCellAlpha,
                accuracy: 0.05,
                "the empty disc is not translucent on a \(dark ? "dark" : "light") bar"
            )
            // The other half: a disc holding something is opaque, so the check above is
            // reading the disc and not an empty corner.
            XCTAssertGreaterThan(try strongestAlpha(in: held.image, leftOf: 14), 0.95)
        }
    }

    // MARK: - the pie

    /// A floor, then shares in proportion: one waiting among fifteen working stays in sight,
    /// and the larger count is still the larger sector.
    func testEverySectorHoldingAnythingGetsAtLeastAFloor() {
        let angles = MenuBarPieSector.angles(for: [1, 15, 0, 0], minimum: 30)

        XCTAssertEqual(angles.reduce(0, +), 360, accuracy: 0.001)
        XCTAssertEqual(angles[2], 0)
        XCTAssertEqual(angles[3], 0)
        XCTAssertGreaterThanOrEqual(angles[0], 30)
        XCTAssertLessThan(angles[0], 60, "the floor swallowed the proportion")
        XCTAssertGreaterThan(angles[1], angles[0])
        XCTAssertEqual(MenuBarPieSector.angles(for: [1, 1, 1, 1], minimum: 30), [90, 90, 90, 90])
        XCTAssertEqual(MenuBarPieSector.angles(for: [0, 0], minimum: 30), [0, 0])
    }

    /// The pie starts at twelve o'clock and runs clockwise in the order of importance, one
    /// sector per state holding anything.
    func testTheSectorsRunClockwiseFromTheTop() throws {
        let drawing = try self.pie(needsPerson: 1, working: 1, done: 0, quiet: 2)
        let pie = drawing.composited()

        XCTAssertEqual(drawing.parts.count, 3, "an empty state was given a sector")
        XCTAssertTrue(try colour(of: pie, angle: 45).isClose(to: drawn(MenuBarIconPalette.needsPerson)))
        XCTAssertTrue(try colour(of: pie, angle: 135).isClose(to: drawn(MenuBarIconPalette.working)))
        XCTAssertTrue(try colour(of: pie, angle: 270).isClose(to: drawn(MenuBarIconPalette.quiet)))
    }

    /// Between two sectors the colours flow into each other, and the disc stays whole: no
    /// gap, and no band the bar shows through — which is what two sectors that each faded out
    /// across the boundary had left.
    func testNeighbouringColoursBlendWithoutOpeningTheDisc() throws {
        let pie = try self.pie(needsPerson: 1, working: 1, done: 1, quiet: 1).composited()

        for angle in stride(from: CGFloat(0), to: 360, by: 3) {
            XCTAssertGreaterThan(try colour(of: pie, angle: angle).alphaComponent, 0.98, "a gap at \(angle)°")
        }
        // The other half: the boundary really is a mix, not a hard edge — and the middle of
        // the sector keeps its own colour.
        let boundary = try colour(of: pie, angle: 90)
        XCTAssertFalse(boundary.isClose(to: try drawn(MenuBarIconPalette.needsPerson)))
        XCTAssertFalse(boundary.isClose(to: try drawn(MenuBarIconPalette.working)))
        XCTAssertTrue(try colour(of: pie, angle: 45).isClose(to: drawn(MenuBarIconPalette.needsPerson)))
    }

    /// Each blend is at most a third of the smaller neighbour, so every sector keeps a middle
    /// in its own colour; and the upper of two neighbours is the one that fades.
    func testEverySectorKeepsAMiddleOfItsOwn() {
        let sectors = MenuBarPieSector.layout(counts: [1, 20, 1], minimumAngle: 30, blendHalfWidth: 90)

        for sector in sectors {
            XCTAssertLessThanOrEqual(sector.startBlend + sector.endBlend, sector.angle * 2 / 3 + 0.001)
        }
        XCTAssertEqual(sectors.map(\.fadesAtStart), [false, true, true])
        XCTAssertEqual(sectors.map(\.fadesAtEnd), [false, false, true], "round the top, the last is the upper")
    }

    /// Nothing to count is an empty circle — not a grey disc, which is what idle looks like.
    func testAnEmptyPieIsARingNotADisc() throws {
        let pie = try self.pie(needsPerson: 0, working: 0, done: 0, quiet: 0)
        let image = pie.composited()

        XCTAssertEqual(pie.parts.count, 1)
        XCTAssertEqual(pie.parts.first?.breathDepth, 0)
        XCTAssertLessThan(try colour(of: image, angle: 0, radius: 0).alphaComponent, 0.05, "the middle is filled")
        XCTAssertGreaterThan(try colour(of: image, angle: 0, radius: 8.25).alphaComponent, 0.3, "no ring")
    }

    /// Sectors breathe as cells do: needs you and working, and only when they hold something.
    func testThePieBreathesTheSectorsAPersonCanActOn() {
        let view = MenuBarIconView()

        view.show(cells(needsPerson: 2, working: 3, done: 1, quiet: 6), as: .pie)
        XCTAssertEqual(view.breathingCells, [0, 1])

        view.show(cells(needsPerson: 0, working: 3, done: 0, quiet: 1), as: .pie)
        XCTAssertEqual(view.breathingCells, [0], "working is the first sector now")

        view.show(cells(needsPerson: 0, working: 0, done: 5, quiet: 4), as: .pie)
        XCTAssertEqual(view.breathingCells, [], "done and idle never breathe")
    }

    // MARK: - the status item

    /// The pie takes the square item the plain glyph has, and the grid its own width and two
    /// points; switching tells the owner of the item.
    func testEachStyleAsksForItsOwnLength() throws {
        let view = MenuBarIconView()
        var reported: [CGFloat] = []
        view.onLengthChange = { reported.append($0) }
        let shown = cells(needsPerson: 1, working: 1, done: 1, quiet: 1)

        view.show(shown, as: .counts)
        XCTAssertEqual(view.itemLength, 49 + MenuBarIconMetrics.itemPadding)
        view.show(shown, as: .pie)
        XCTAssertEqual(view.itemLength, NSStatusItem.squareLength)
        view.show(cells(needsPerson: 12, working: 1, done: 1, quiet: 1), as: .pie)

        XCTAssertEqual(reported, [51, NSStatusItem.squareLength], "the pie moved with its numbers")
    }

    /// The same numbers in another style are a new drawing, and the bar has to be asked.
    func testChangingStyleAsksForARedraw() {
        let view = MenuBarIconView()
        let shown = cells(needsPerson: 1, working: 1, done: 0, quiet: 0)
        view.show(shown, as: .counts)
        let before = view.redrawRequests

        XCTAssertTrue(view.show(shown, as: .pie))

        XCTAssertEqual(view.redrawRequests, before + 1)
    }

    /// The plain glyph is the item's own image, never this view's drawing.
    func testTheViewDoesNotDrawTheAppIcon() {
        XCTAssertFalse(MenuBarIconView().show(cells(needsPerson: 1, working: 0, done: 0, quiet: 0), as: .appIcon))
        XCTAssertNil(MenuBarPieRenderer.draw([], dark: true))
    }

    // MARK: - helpers

    private func cells(
        showing shown: Set<SessionAttention> = Set(SessionAttention.counted),
        needsPerson: Int = 1,
        working: Int = 1,
        done: Int = 1,
        quiet: Int = 1
    ) -> [MenuBarIconCell] {
        MenuBarIconCell.cells(
            for: SessionAttentionCounts(needsPerson: needsPerson, working: working, done: done, quiet: quiet),
            showing: shown
        )
    }

    private func grid(showing shown: Set<SessionAttention>) throws -> MenuBarIconDrawing {
        try XCTUnwrap(MenuBarIconRenderer.draw(cells(showing: shown), dark: true), "no symbols for the grid")
    }

    private func pie(needsPerson: Int, working: Int, done: Int, quiet: Int) throws -> MenuBarIconDrawing {
        try XCTUnwrap(
            MenuBarPieRenderer.draw(
                cells(needsPerson: needsPerson, working: working, done: done, quiet: quiet),
                dark: true
            )
        )
    }

    /// The colour at a point of the pie, `angle` clockwise from twelve o'clock and `radius`
    /// from its centre, in points.
    private func colour(of image: NSImage, angle: CGFloat, radius: CGFloat = 6) throws -> NSColor {
        let radians = angle * .pi / 180
        let point = NSPoint(
            x: image.size.width / 2 + radius * sin(radians),
            y: image.size.height / 2 + radius * cos(radians)
        )
        let map = try bitmap(of: image)
        let step = image.size.width / CGFloat(map.pixelsWide)
        let column = min(map.pixelsWide - 1, Int(point.x / step))
        let row = min(map.pixelsHigh - 1, Int((image.size.height - point.y) / step))
        return try XCTUnwrap(map.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
    }

    /// A colour as the icon's own drawing puts it down: filled into an image made with
    /// `lockFocus`, like every part, and read back the same way.
    ///
    /// Not the palette's numbers. An image made that way is kept in the screen's profile, and
    /// the palette's grey 0.62 comes back from one as 0.68 — a plain square of it does too. The
    /// question here is which sector sits where, not how the screen's profile treats a colour.
    private func drawn(_ colour: NSColor) throws -> NSColor {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        colour.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let map = try bitmap(of: image)
        return try XCTUnwrap(map.colorAt(x: map.pixelsWide / 2, y: map.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func strongestAlpha(in image: NSImage, leftOf right: CGFloat) throws -> CGFloat {
        let map = try bitmap(of: image)
        let step = image.size.width / CGFloat(map.pixelsWide)
        var strongest: CGFloat = 0
        for row in 0..<map.pixelsHigh {
            for column in 0..<map.pixelsWide where CGFloat(column) * step < right {
                strongest = max(strongest, map.colorAt(x: column, y: row)?.alphaComponent ?? 0)
            }
        }
        return strongest
    }

    /// The box of half-lit pixels left of `right`, in points from the bottom left.
    private func ink(of image: NSImage, leftOf right: CGFloat) throws -> NSRect? {
        let map = try bitmap(of: image)
        let step = image.size.width / CGFloat(map.pixelsWide)
        var box: NSRect?
        for row in 0..<map.pixelsHigh {
            for column in 0..<map.pixelsWide
            where CGFloat(column) * step < right && (map.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.5 {
                let pixel = NSRect(
                    x: CGFloat(column) * step,
                    y: image.size.height - CGFloat(row + 1) * step,
                    width: step,
                    height: step
                )
                box = box.map { $0.union(pixel) } ?? pixel
            }
        }
        return box
    }

    /// Drawn afresh into a bitmap that is sRGB by construction, at two pixels a point.
    ///
    /// Not `tiffRepresentation`: its bitmap came back tagged as a space the pixels were not
    /// drawn in, and every colour read from it was off by a gamma — the palette's grey 0.62
    /// read as 0.68.
    private func bitmap(of image: NSImage) throws -> NSBitmapImageRep {
        let map = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(image.size.width * 2),
                pixelsHigh: Int(image.size.height * 2),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )?.retagging(with: .sRGB)
        )
        map.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: map)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return map
    }
}

extension NSColor {
    /// Within a few units in each channel, in sRGB.
    fileprivate func isClose(to other: NSColor, tolerance: CGFloat = 0.06) -> Bool {
        guard let mine = usingColorSpace(.sRGB), let theirs = other.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(mine.redComponent - theirs.redComponent) <= tolerance
            && abs(mine.greenComponent - theirs.greenComponent) <= tolerance
            && abs(mine.blueComponent - theirs.blueComponent) <= tolerance
    }
}
