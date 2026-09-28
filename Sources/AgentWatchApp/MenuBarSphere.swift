import AgentWatchCore
import AppKit

/// Every number the sphere is drawn from, each chosen from drawings of it at actual size and
/// enlarged — `MenuBarIconStyleProbe` draws them again.
enum MenuBarSphereMetrics {
    /// Two points short of the bar at each end. Sixteen, the size of the plain glyph, was drawn
    /// beside it and read as the smaller icon for no gain.
    static let diameter: CGFloat = 18
    /// The least share of the sphere a state holding anything is given: half for the sessions
    /// that need a person, a twelfth for the rest.
    ///
    /// Half, because a share true to the numbers is the wrong answer to the one question the
    /// icon is for: one session waiting among eleven idle is a twelfth of the sphere, and next
    /// to them it looked like nothing. The owner asked for no less than half.
    static let needsPersonFloor: CGFloat = 0.5
    static let otherFloor: CGFloat = 1.0 / 12
    /// Idle, in the sphere's own colour rather than the grid's grey. The owner chose it from
    /// drawings of both side by side: grey mixed into its neighbours reads as a dull patch,
    /// and a soft violet as a colour of its own. It is the least saturated of the four, which
    /// keeps idle the quietest.
    static let quiet = NSColor(srgbRed: 0.52, green: 0.50, blue: 0.90, alpha: 1)
    /// How far from the middle each state's colour is centred, as a share of the radius.
    static let anchorDistance: CGFloat = 0.52
    /// How widely a colour spreads from its centre, as a share of the radius, for a state
    /// holding a quarter of the sphere; larger shares spread wider.
    static let spread: CGFloat = 0.42
    /// How much darker the rim is than the middle.
    static let rimDarkening: CGFloat = 0.16
    /// How far the bottom goes towards white.
    static let bottomGlow: CGFloat = 0.38
    /// The highlight, as a share of the radius, and how strong it is. Upper left rather than
    /// on top, where needs you sits, so that white does not wash its orange out.
    static let highlightCentre = CGPoint(x: -0.36, y: 0.44)
    static let highlightRadius: CGFloat = 0.32
    static let highlightStrength: CGFloat = 0.95
    /// How far the whole sphere fades at the bottom of its breath, while anything needs a
    /// person. Nothing else makes it breathe.
    static let breathDepth: CGFloat = 0.55
    /// The line an empty sphere is drawn with.
    static let emptyLineWidth: CGFloat = 1.5
}

/// One state's place on the sphere: how much of it the state holds, and where its colour is
/// centred.
struct MenuBarSphereShare: Equatable {
    let share: CGFloat
    /// Clockwise from twelve o'clock, in degrees.
    let angle: CGFloat
}

/// Draws the counts as one sphere, each state's colour a soft patch on it, lit from above.
///
/// One picture rather than a part per state, as the grid has: the sphere breathes as a whole,
/// and only while something needs a person, so nothing on it moves on its own.
@MainActor
enum MenuBarSphereRenderer {
    /// `nil` only for no cells at all. A sphere whose states hold nothing is an empty ring, not
    /// no drawing: the grid shows its zeros, and the sphere says the same thing its own way.
    ///
    /// `scale` is pixels per point. The sphere is painted a pixel at a time, so it has to be
    /// painted for the screen it is shown on rather than scaled to it.
    static func draw(_ cells: [MenuBarIconCell], dark: Bool, scale: CGFloat = 2) -> MenuBarIconDrawing? {
        guard !cells.isEmpty else {
            return nil
        }
        let size = NSSize(width: MenuBarSphereMetrics.diameter, height: MenuBarIconMetrics.barHeight)
        let frame = NSRect(origin: .zero, size: size)
        let held = cells.filter { $0.count > 0 }
        guard let first = held.first else {
            return MenuBarIconDrawing(
                size: size,
                parts: [MenuBarIconPart(image: emptyRing(size: size, dark: dark), frame: frame, breathDepth: 0)]
            )
        }
        // The cells come in their order of importance, so needs you, when it holds anything,
        // is the first.
        let needsPerson = first.attention == .needsPerson
        let shares = MenuBarSphereShare.layout(counts: held.map(\.count), needsPersonFirst: needsPerson)
        let colours = held.map { $0.attention == .quiet ? MenuBarSphereMetrics.quiet : $0.accent }
        return MenuBarIconDrawing(
            size: size,
            parts: [
                MenuBarIconPart(
                    image: paint(shares: shares, colours: colours, size: size, scale: scale),
                    frame: frame,
                    breathDepth: needsPerson ? MenuBarSphereMetrics.breathDepth : 0
                )
            ]
        )
    }

    private struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat

        init(_ colour: NSColor) {
            let c = colour.usingColorSpace(.sRGB) ?? colour
            r = c.redComponent
            g = c.greenComponent
            b = c.blueComponent
        }

        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
        }

        func mixed(with other: RGB, by t: CGFloat) -> RGB {
            RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }

        func scaled(by k: CGFloat) -> RGB {
            RGB(r: r * k, g: g * k, b: b * k)
        }
    }

    /// Each pixel is the mix of every state's colour, weighted by how much of the sphere the
    /// state holds and how close the pixel is to its centre — so the colours flow into one
    /// another with no boundary anywhere, and a larger share is a larger patch.
    ///
    /// Painted into an sRGB bitmap rather than with `lockFocus`, whose image is kept in the
    /// screen's profile: the colours here are mixed by arithmetic, and have to be stored as
    /// the numbers they were mixed to.
    private static func paint(shares: [MenuBarSphereShare], colours: [NSColor], size: NSSize, scale: CGFloat)
        -> NSImage
    {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard
            let map = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )?.retagging(with: .sRGB),
            let data = map.bitmapData
        else {
            return NSImage(size: size)
        }
        map.size = size
        let radius = MenuBarSphereMetrics.diameter / 2 * scale
        let centre = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        let palette = colours.map(RGB.init)
        let anchors = shares.map { share -> CGPoint in
            guard shares.count > 1 else {
                return .zero
            }
            let radians = share.angle * .pi / 180
            return CGPoint(
                x: MenuBarSphereMetrics.anchorDistance * sin(radians),
                y: MenuBarSphereMetrics.anchorDistance * cos(radians)
            )
        }
        let spreads = shares.map { MenuBarSphereMetrics.spread * sqrt($0.share / 0.25) }
        let white = RGB(r: 1, g: 1, b: 1)
        let highlight = MenuBarSphereMetrics.highlightCentre
        let highlightRadius = MenuBarSphereMetrics.highlightRadius

        for row in 0..<height {
            for column in 0..<width {
                // Unit coordinates, y up, the sphere's edge at 1.
                let x = (CGFloat(column) + 0.5 - centre.x) / radius
                let y = (centre.y - (CGFloat(row) + 0.5)) / radius
                let distance = sqrt(x * x + y * y)
                let coverage = min(max((1 - distance) * radius + 0.5, 0), 1)
                let offset = row * map.bytesPerRow + column * 4
                guard coverage > 0 else {
                    for channel in 0..<4 {
                        data[offset + channel] = 0
                    }
                    continue
                }
                var total: CGFloat = 0
                var colour = RGB(r: 0, g: 0, b: 0)
                for index in shares.indices {
                    let dx = x - anchors[index].x
                    let dy = y - anchors[index].y
                    let spread = spreads[index]
                    let weight = shares[index].share * exp(-(dx * dx + dy * dy) / (2 * spread * spread))
                    colour.r += palette[index].r * weight
                    colour.g += palette[index].g * weight
                    colour.b += palette[index].b * weight
                    total += weight
                }
                colour = colour.scaled(by: 1 / max(total, .leastNonzeroMagnitude))
                // Lit from above: darker towards the rim, a haze of light at the bottom, and
                // one small highlight.
                colour = colour.scaled(by: 1 - MenuBarSphereMetrics.rimDarkening * pow(distance, 3))
                let glow = MenuBarSphereMetrics.bottomGlow * smoothstep(0.15, 1, -y) * smoothstep(0.3, 1, distance)
                colour = colour.mixed(with: white, by: glow)
                let hx = (x - highlight.x) / highlightRadius
                let hy = (y - highlight.y) / (highlightRadius * 0.7)
                colour = colour.mixed(
                    with: white,
                    by: MenuBarSphereMetrics.highlightStrength * exp(-(hx * hx + hy * hy) * 1.6)
                )

                // Premultiplied, as the bitmap stores it.
                data[offset] = UInt8(min(max(colour.r, 0), 1) * coverage * 255)
                data[offset + 1] = UInt8(min(max(colour.g, 0), 1) * coverage * 255)
                data[offset + 2] = UInt8(min(max(colour.b, 0), 1) * coverage * 255)
                data[offset + 3] = UInt8(coverage * 255)
            }
        }
        let image = NSImage(size: size)
        image.addRepresentation(map)
        image.isTemplate = false
        return image
    }

    private static func smoothstep(_ lower: CGFloat, _ upper: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(max((value - lower) / (upper - lower), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The same translucent ink the grid draws an empty cell with, as a ring: a disc of it
    /// would read as a sphere holding something.
    private static func emptyRing(size: NSSize, dark: Bool) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        let line = MenuBarSphereMetrics.emptyLineWidth
        let radius = MenuBarSphereMetrics.diameter / 2 - line / 2
        let centre = NSPoint(x: size.width / 2, y: size.height / 2)
        let ring = NSBezierPath(
            ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        )
        ring.lineWidth = line
        NSColor(white: dark ? 1 : 0, alpha: MenuBarIconMetrics.emptyCellAlpha).setStroke()
        ring.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

extension MenuBarSphereShare {
    /// Each count's share, in the order given — the order of importance, needs you first when
    /// it is there. Every count is one that holds something.
    ///
    /// Needs you never holds less than half; any other state holding anything holds at least a
    /// twelfth. The floors are given first and the rest is shared by count, so a larger count
    /// is always a larger share. The floors come to three quarters at most — needs you and the
    /// three others — so something is always left to share.
    ///
    /// Needs you is centred on twelve o'clock and the rest follow it clockwise.
    static func layout(counts: [Int], needsPersonFirst: Bool) -> [MenuBarSphereShare] {
        guard !counts.isEmpty else {
            return []
        }
        let floors = counts.indices.map { index in
            needsPersonFirst && index == 0 ? MenuBarSphereMetrics.needsPersonFloor : MenuBarSphereMetrics.otherFloor
        }
        let left = 1 - floors.reduce(0, +)
        let total = CGFloat(counts.reduce(0, +))
        let shares = counts.indices.map { floors[$0] + left * CGFloat(counts[$0]) / total }
        var start = -shares[0] * 180
        return shares.map { share in
            defer { start += share * 360 }
            return MenuBarSphereShare(share: share, angle: start + share * 180)
        }
    }
}
