import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The icon with fewer than four states, the sphere, and what either asks of the status item.
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

    // MARK: - the sphere

    /// Needs you holds at least half the sphere, however many others there are; the rest get a
    /// floor of their own and share what is left by count.
    func testNeedsYouHoldsAtLeastHalf() {
        let lonely = MenuBarSphereShare.layout(counts: [1, 11], needsPersonFirst: true).map(\.share)
        XCTAssertGreaterThanOrEqual(lonely[0], 0.5, "one waiting among eleven idle is lost again")
        XCTAssertEqual(lonely.reduce(0, +), 1, accuracy: 0.0001)

        // The other half: past the floor it still follows the numbers.
        let crowded = MenuBarSphereShare.layout(counts: [10, 1], needsPersonFirst: true).map(\.share)
        XCTAssertGreaterThan(crowded[0], 0.8, "the floor swallowed the proportion")

        let mixed = MenuBarSphereShare.layout(counts: [1, 3, 1, 6], needsPersonFirst: true).map(\.share)
        XCTAssertGreaterThanOrEqual(mixed[0], 0.5)
        XCTAssertGreaterThan(mixed[3], mixed[1], "a larger count is not a larger share")
        XCTAssertGreaterThan(mixed[1], mixed[2])
        XCTAssertGreaterThanOrEqual(mixed[2], MenuBarSphereMetrics.otherFloor)
    }

    /// Without needs you nobody is given half: the floor is only for the state that wants a
    /// person.
    func testWithoutNeedsYouTheSharesFollowTheCounts() {
        let shares = MenuBarSphereShare.layout(counts: [1, 15], needsPersonFirst: false).map(\.share)

        XCTAssertGreaterThanOrEqual(shares[0], MenuBarSphereMetrics.otherFloor)
        XCTAssertLessThan(shares[0], 0.25)
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 0.0001)
    }

    /// Needs you is centred on twelve o'clock and the rest follow it clockwise.
    func testNeedsYouSitsOnTopAndTheRestFollowClockwise() {
        let angles = MenuBarSphereShare.layout(counts: [1, 3, 1, 6], needsPersonFirst: true).map(\.angle)

        XCTAssertEqual(angles[0], 0, accuracy: 0.0001)
        XCTAssertEqual(angles, angles.sorted(), "not clockwise")
        XCTAssertLessThan(angles[3], 360)
    }

    /// On the drawing, needs you is the colour at the top and idle — in the sphere's own
    /// violet — the colour at the bottom, and the highlight has not washed the orange out.
    func testNeedsYouIsOrangeOnTopAndIdleVioletBelow() throws {
        let sphere = try self.sphere(needsPerson: 1, working: 0, done: 0, quiet: 11).composited()
        let shown = [MenuBarIconPalette.needsPerson, MenuBarSphereMetrics.quiet]
        let anchor = MenuBarSphereMetrics.anchorDistance * MenuBarSphereMetrics.diameter / 2

        let top = try colour(of: sphere, angle: 0, radius: anchor)
        let bottom = try colour(of: sphere, angle: 180, radius: anchor)

        XCTAssertEqual(nearest(to: top, among: shown), 0, "needs you is not on top")
        XCTAssertEqual(nearest(to: bottom, among: shown), 1, "idle is not below")
        XCTAssertLessThan(top.blueComponent, 0.3, "the highlight sits on needs you")
    }

    /// One picture for the whole sphere, whatever it shows: it breathes as one.
    func testTheSphereIsOnePart() throws {
        XCTAssertEqual(try sphere(needsPerson: 2, working: 3, done: 1, quiet: 6).parts.count, 1)
        XCTAssertEqual(try sphere(needsPerson: 0, working: 3, done: 0, quiet: 1).parts.count, 1)
    }

    /// The whole sphere breathes, and only while somebody needs a person. Working breathes in
    /// the grid; on the sphere it would make the one mark move for something nobody has to
    /// answer.
    func testTheWholeSphereBreathesOnlyWhenSomeoneIsNeeded() {
        let view = MenuBarIconView()

        view.show(cells(needsPerson: 2, working: 3, done: 1, quiet: 6), as: .sphere)
        XCTAssertEqual(view.breathingCells, [0])

        view.show(cells(needsPerson: 0, working: 3, done: 0, quiet: 1), as: .sphere)
        XCTAssertEqual(view.breathingCells, [], "working made the sphere breathe")

        view.show(cells(needsPerson: 0, working: 0, done: 5, quiet: 4), as: .sphere)
        XCTAssertEqual(view.breathingCells, [])
    }

    /// Nothing to count is an empty circle — not a violet sphere, which is what idle looks like.
    func testAnEmptySphereIsARingNotADisc() throws {
        let sphere = try self.sphere(needsPerson: 0, working: 0, done: 0, quiet: 0)
        let image = sphere.composited()

        XCTAssertEqual(sphere.parts.count, 1)
        XCTAssertEqual(sphere.parts.first?.breathDepth, 0)
        XCTAssertLessThan(try colour(of: image, angle: 0, radius: 0).alphaComponent, 0.05, "the middle is filled")
        XCTAssertGreaterThan(try colour(of: image, angle: 0, radius: 8.25).alphaComponent, 0.3, "no ring")
    }

    /// Painted a pixel at a time, the sphere is painted at the screen's scale, and the layer is
    /// handed that picture rather than a smaller one to stretch.
    func testTheSphereIsPaintedAtTheScreensScale() throws {
        let drawn = try XCTUnwrap(
            MenuBarSphereRenderer.draw(cells(needsPerson: 1, working: 1, done: 1, quiet: 1), dark: true, scale: 3)
        )
        let image = try XCTUnwrap(drawn.parts.first?.image)
        let map = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(map.pixelsWide, 54)
        XCTAssertEqual(map.size, image.size, "the bitmap claims to be larger than the picture")

        let view = MenuBarIconView()
        view.show(cells(needsPerson: 1, working: 1, done: 1, quiet: 1), as: .sphere)
        let contents = try XCTUnwrap(view.cellContents.first ?? nil)
        // Outside a window the view has no screen to ask and paints for two pixels a point.
        XCTAssertEqual((contents as! CGImage).width, 36)
    }

    // MARK: - the status item

    /// The sphere takes the square item the plain glyph has, and the grid its own width and two
    /// points; switching tells the owner of the item.
    func testEachStyleAsksForItsOwnLength() throws {
        let view = MenuBarIconView()
        var reported: [CGFloat] = []
        view.onLengthChange = { reported.append($0) }
        let shown = cells(needsPerson: 1, working: 1, done: 1, quiet: 1)

        view.show(shown, as: .counts)
        XCTAssertEqual(view.itemLength, 49 + MenuBarIconMetrics.itemPadding)
        view.show(shown, as: .sphere)
        XCTAssertEqual(view.itemLength, NSStatusItem.squareLength)
        view.show(cells(needsPerson: 12, working: 1, done: 1, quiet: 1), as: .sphere)

        XCTAssertEqual(reported, [51, NSStatusItem.squareLength], "the sphere moved with its numbers")
    }

    /// The same numbers in another style are a new drawing, and the bar has to be asked.
    func testChangingStyleAsksForARedraw() {
        let view = MenuBarIconView()
        let shown = cells(needsPerson: 1, working: 1, done: 0, quiet: 0)
        view.show(shown, as: .counts)
        let before = view.redrawRequests

        XCTAssertTrue(view.show(shown, as: .sphere))

        XCTAssertEqual(view.redrawRequests, before + 1)
    }

    /// No states at all is no drawing: the view can be asked to repaint — the bar turned dark —
    /// before it was ever given anything to draw.
    func testNoStatesIsNoSphere() {
        XCTAssertNil(MenuBarSphereRenderer.draw([], dark: true))
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

    private func sphere(needsPerson: Int, working: Int, done: Int, quiet: Int) throws -> MenuBarIconDrawing {
        try XCTUnwrap(
            MenuBarSphereRenderer.draw(
                cells(needsPerson: needsPerson, working: working, done: done, quiet: quiet),
                dark: true
            )
        )
    }

    /// The colour at a point of the sphere, `angle` clockwise from twelve o'clock and `radius`
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

    /// Which of `colours` this one is closest to, in sRGB.
    ///
    /// Not a match within a tolerance: the sphere's shading moves every colour on it off the
    /// palette's numbers, and the question is only which state a point belongs to.
    private func nearest(to colour: NSColor, among colours: [NSColor]) -> Int? {
        func distance(_ other: NSColor) -> CGFloat {
            guard let mine = colour.usingColorSpace(.sRGB), let theirs = other.usingColorSpace(.sRGB) else {
                return .infinity
            }
            let r = mine.redComponent - theirs.redComponent
            let g = mine.greenComponent - theirs.greenComponent
            let b = mine.blueComponent - theirs.blueComponent
            return r * r + g * g + b * b
        }
        return colours.indices.min { distance(colours[$0]) < distance(colours[$1]) }
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

/// The image the button is given under the drawing, which decides how the other screens
/// blend their copy of the item.
@MainActor
final class MenuBarIconPlaceholderTests: XCTestCase {
    /// Not a template, and nothing in it: the drawing on top is the only thing to see.
    func testTheButtonGetsAClearImageThatIsNotATemplate() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
        let view = MenuBarIconView()
        button.addSubview(view)

        view.show(MenuBarIconCell.cells(for: SessionAttentionCounts(needsPerson: 1, working: 1, done: 1, quiet: 1)))
        view.fill(button)

        let image = try XCTUnwrap(button.image, "the button was left without an image, and gets blended as a template")
        XCTAssertFalse(image.isTemplate)
        let map = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let alphas = (0..<map.pixelsHigh).flatMap { row in
            (0..<map.pixelsWide).map { map.colorAt(x: $0, y: row)?.alphaComponent ?? 1 }
        }
        XCTAssertEqual(alphas.max(), 0, "the placeholder shows through")
    }

    /// As wide as the drawing, and it follows the drawing when a column reaches two digits.
    func testThePlaceholderFollowsTheDrawingsWidth() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
        let view = MenuBarIconView()
        button.addSubview(view)
        view.show(MenuBarIconCell.cells(for: SessionAttentionCounts(needsPerson: 1, working: 1, done: 1, quiet: 1)))
        view.fill(button)
        XCTAssertEqual(button.image?.size.width, 49)

        view.show(MenuBarIconCell.cells(for: SessionAttentionCounts(needsPerson: 12, working: 1, done: 1, quiet: 1)))

        XCTAssertEqual(button.image?.size.width, 57, "the other screens would cut the wider grid")
    }
}
