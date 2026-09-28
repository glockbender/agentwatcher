import AppKit

/// Every number the pie is drawn from, each settled by looking at it at actual size.
enum MenuBarPieMetrics {
    /// Two points short of the bar at each end. Sixteen, the size of the plain glyph, was drawn
    /// beside it and read as the smaller icon for no gain.
    static let diameter: CGFloat = 18
    /// The least a sector holding anything is drawn at, in degrees.
    ///
    /// A pie drawn true to its numbers is the wrong answer to the one question this icon is
    /// for: one session waiting among fifteen working is 22°, and on a light bar that sliver
    /// all but vanished. A twelfth of the disc keeps it in sight, at the price of showing a
    /// small share a little larger than it is.
    static let minimumAngle: CGFloat = 30
    /// How far either side of a boundary two neighbouring colours blend, in degrees, at most.
    ///
    /// Drawn at 0, 6, 12, 20 and as wide as a sector allows: 6 reads as a soft edge rather
    /// than a gradient, and at the widest the colours run into one another until a sector is
    /// mostly its neighbours. Twenty is a gradient that still leaves every sector a solid
    /// middle of its own.
    static let blendHalfWidth: CGFloat = 20
    /// The width of each of the thin wedges a blend is painted with.
    static let blendStep: CGFloat = 1
    /// The line an empty pie is drawn with.
    static let emptyLineWidth: CGFloat = 1.5
}

/// Draws the counts as one disc, a sector for each state that holds anything, the colours
/// flowing into one another at the boundaries.
///
/// Each sector is its own part, so that it breathes on its own layer as a cell of the grid
/// does. That is what shapes the blend. Two sectors that each faded out across the boundary
/// would leave a band there the bar shows through — faded halves of two layers over each other
/// do not add up to one opaque layer — so only one of them fades: the upper one thins out over
/// its neighbour, and the neighbour carries on, solid, underneath. Breathing either one then
/// changes the mix without opening a gap.
@MainActor
enum MenuBarPieRenderer {
    /// `nil` only for no cells at all. A pie whose states hold nothing is an empty circle, not
    /// no drawing: the grid shows its zeros, and the pie says the same thing its own way.
    static func draw(
        _ cells: [MenuBarIconCell],
        dark: Bool,
        blendHalfWidth: CGFloat = MenuBarPieMetrics.blendHalfWidth
    ) -> MenuBarIconDrawing? {
        guard !cells.isEmpty else {
            return nil
        }
        let size = NSSize(width: MenuBarPieMetrics.diameter, height: MenuBarIconMetrics.barHeight)
        let frame = NSRect(origin: .zero, size: size)
        let held = cells.filter { $0.count > 0 }
        guard !held.isEmpty else {
            return MenuBarIconDrawing(
                size: size,
                parts: [MenuBarIconPart(image: emptyCircle(size: size, dark: dark), frame: frame, breathDepth: 0)]
            )
        }

        let sectors = MenuBarPieSector.layout(
            counts: held.map(\.count),
            minimumAngle: MenuBarPieMetrics.minimumAngle,
            blendHalfWidth: blendHalfWidth
        )
        let parts = zip(held, sectors).map { cell, sector in
            MenuBarIconPart(
                image: draw(sector, colour: cell.accent, size: size),
                frame: frame,
                breathDepth: cell.breathDepth
            )
        }
        return MenuBarIconDrawing(size: size, parts: parts)
    }

    /// The disc, masked by the sector's own coverage.
    ///
    /// The wedges are filled without antialiasing and the disc with it: wedges that each
    /// smoothed their own edges would leave a faint seam at every one of their boundaries, a
    /// degree apart all the way round.
    ///
    /// And each wedge replaces what is under it rather than going over it. Near the middle a
    /// pixel spans several degrees, so several wedges fill it; laid over one another their
    /// translucency added up, and the blend came out harder than asked and ten degrees off
    /// where it belonged — measured, 0.97 where the boundary should read 0.5.
    private static func draw(_ sector: MenuBarPieSector, colour: NSColor, size: NSSize) -> NSImage {
        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let radius = MenuBarPieMetrics.diameter / 2

        let coverage = NSImage(size: size)
        coverage.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = false
        NSGraphicsContext.current?.compositingOperation = .copy
        var angle = sector.from
        while angle < sector.to {
            let next = min(angle + MenuBarPieMetrics.blendStep, sector.to)
            colour.withAlphaComponent(sector.opacity(at: (angle + next) / 2)).setFill()
            let wedge = NSBezierPath()
            wedge.move(to: center)
            // Past the rim, so that the disc below is what gives the edge its shape.
            wedge.appendArc(
                withCenter: center,
                radius: radius + 1,
                startAngle: 90 - angle,
                endAngle: 90 - next,
                clockwise: true
            )
            wedge.close()
            wedge.fill()
            angle = next
        }
        coverage.unlockFocus()

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            .fill()
        coverage.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceIn, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// The same translucent ink the grid draws an empty cell with, as a ring: a disc of it
    /// would read as a sector of idle sessions, which are grey too.
    private static func emptyCircle(size: NSSize, dark: Bool) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let line = MenuBarPieMetrics.emptyLineWidth
        let radius = MenuBarPieMetrics.diameter / 2 - line / 2
        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let circle = NSBezierPath(
            ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        )
        circle.lineWidth = line
        NSColor(white: dark ? 1 : 0, alpha: MenuBarIconMetrics.emptyCellAlpha).setStroke()
        circle.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

/// One sector of the pie: its share of the circle, and how it blends into its neighbours.
///
/// Angles are in degrees, clockwise from twelve o'clock, and may run below zero or past 360
/// where a sector reaches across the top into its neighbour.
struct MenuBarPieSector: Equatable {
    /// Where the sector's own share begins and ends.
    let start: CGFloat
    let end: CGFloat
    /// How far each boundary blends, on either side of it.
    let startBlend: CGFloat
    let endBlend: CGFloat
    /// Whether the sector thins out over its neighbour at that boundary, rather than carrying
    /// on underneath it.
    let fadesAtStart: Bool
    let fadesAtEnd: Bool

    var angle: CGFloat {
        end - start
    }

    /// The whole stretch it paints, its share and whatever it reaches into either side.
    var from: CGFloat {
        start - startBlend
    }

    var to: CGFloat {
        end + endBlend
    }

    func opacity(at angle: CGFloat) -> CGFloat {
        var opacity: CGFloat = 1
        if fadesAtStart, startBlend > 0 {
            opacity = min(opacity, Self.smoothstep((angle - from) / (2 * startBlend)))
        }
        if fadesAtEnd, endBlend > 0 {
            opacity = min(opacity, Self.smoothstep((to - angle) / (2 * endBlend)))
        }
        return opacity
    }

    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// One sector per count, all of them non-zero, in the order given and in the order they
    /// are stacked: the first at the bottom.
    ///
    /// At each boundary the upper of the two sectors fades and the lower carries on beneath
    /// it. Round the top, where the last meets the first, the last is the upper.
    static func layout(counts: [Int], minimumAngle: CGFloat, blendHalfWidth: CGFloat) -> [MenuBarPieSector] {
        let angles = angles(for: counts, minimum: minimumAngle)
        guard angles.count > 1 else {
            return angles.map {
                MenuBarPieSector(
                    start: 0, end: $0, startBlend: 0, endBlend: 0, fadesAtStart: false, fadesAtEnd: false
                )
            }
        }
        let starts = angles.indices.map { angles[..<$0].reduce(0, +) }
        // A third of the smaller neighbour at most, so every sector keeps a third of itself in
        // its own colour whatever it sits between.
        let blends = angles.indices.map { index in
            let before = angles[(index + angles.count - 1) % angles.count]
            return min(blendHalfWidth, before / 3, angles[index] / 3)
        }
        let last = angles.count - 1
        return angles.indices.map { index in
            MenuBarPieSector(
                start: starts[index],
                end: starts[index] + angles[index],
                startBlend: blends[index],
                endBlend: blends[(index + 1) % angles.count],
                fadesAtStart: index != 0,
                fadesAtEnd: index == last
            )
        }
    }

    /// Each count's share of the circle: zero for an empty one, never less than `minimum` for
    /// any other, and 360 in all.
    ///
    /// The floor is given first and the rest is shared in proportion, rather than raising the
    /// small shares and taking the difference out of the large ones: that keeps a larger count
    /// a larger sector whatever the numbers are.
    static func angles(for counts: [Int], minimum: CGFloat) -> [CGFloat] {
        let total = counts.reduce(0, +)
        let held = counts.filter { $0 > 0 }.count
        guard total > 0 else {
            return counts.map { _ in 0 }
        }
        let floor = min(minimum, 360 / CGFloat(held))
        let shared = 360 - floor * CGFloat(held)
        return counts.map { $0 > 0 ? floor + shared * CGFloat($0) / CGFloat(total) : 0 }
    }
}
