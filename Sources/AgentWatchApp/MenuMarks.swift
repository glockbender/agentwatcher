import AgentWatchCore
import AppKit
import QuartzCore

/// The marks of the menu's session lines: in the colours the theme gives them, and moving while
/// the menu is open when the theme asks for it (`WidgetTheme.Look.menuMarkStyle`).
///
/// A menu line's picture is an image, not a layer, so a movement is drawn as a new image a
/// dozen times a second — and only while the menu is open, since nothing sees it otherwise. The
/// frames are taken off the same clock the widget's lamps run on, so a line and its row move
/// in step.
///
/// An open menu redraws a line whose image is replaced: the owner watched a waiting session's
/// mark breathe on macOS 15.3.1 (`docs/measurements.md`). Nothing moves until a theme asks: the
/// built-in one holds the marks still.
@MainActor
final class MenuMarkAnimator {
    private struct Mark {
        let item: NSMenuItem
        let attention: SessionAttention
        let style: LampStyle
    }

    private var marks: [Mark] = []
    private var timer: Timer?
    static let framesPerSecond: Double = 12

    /// Draws these lines' marks as they stand still, and remembers the ones that move.
    func show(_ lines: [(item: NSMenuItem, attention: SessionAttention, style: LampStyle)]) {
        marks = lines.map { Mark(item: $0.item, attention: $0.attention, style: $0.style) }
        for mark in marks {
            mark.item.image = Self.frame(of: mark.style, attention: mark.attention, at: CACurrentMediaTime())
        }
        if !isMoving {
            stop()
        }
    }

    /// Whether any mark shown moves at all.
    var isMoving: Bool {
        marks.contains { $0.style.motion != .steady }
    }

    var isRunning: Bool {
        timer != nil
    }

    func start() {
        guard isMoving, timer == nil else {
            return
        }
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.drawFrame()
            }
        }
        // Common modes: a menu tracks the mouse in a run-loop mode of its own, and a timer
        // left in the default mode would not fire while the menu is open — the one time it has
        // to.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func drawFrame() {
        let now = CACurrentMediaTime()
        for mark in marks where mark.style.motion != .steady {
            mark.item.image = Self.frame(of: mark.style, attention: mark.attention, at: now)
        }
    }

    /// The mark at one moment of its movement.
    ///
    /// The same curve the lamps' layer animations follow, out and back: 0 at the start of a
    /// cycle, 1 halfway, raised-cosine in between.
    static func frame(of style: LampStyle, attention: SessionAttention, at time: CFTimeInterval) -> NSImage? {
        let cycle = max(style.animationCycle, 0.1)
        let progress = (1 - cos(time.truncatingRemainder(dividingBy: cycle) / cycle * 2 * .pi)) / 2
        switch style.motion {
        case .steady:
            return mark(for: attention, colour: style.color)
        case .dim:
            return mark(for: attention, colour: style.color, alpha: 1 - attention.breathDepth * CGFloat(progress))
        case .gradient:
            return mark(for: attention, colour: style.color.mixed(with: style.gradientColor, by: CGFloat(progress)))
        }
    }

    /// The state's mark, in a colour: the shape tells the states apart on its own, so the
    /// colour only speeds the reading (ADR-0003).
    ///
    /// Two palette colours, the mark first. Given only the accent, the palette paints every
    /// layer with it — drawn offscreen, all four came out as plain discs of four colours, which
    /// is the one thing ADR-0003 rules out. The menu bar cuts the mark out of the disc instead;
    /// a menu has a background of its own, so a white mark reads the same on a light and a
    /// dark one.
    static func mark(for attention: SessionAttention, colour: NSColor, alpha: CGFloat = 1) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, colour]))
        guard
            let symbol = NSImage(systemSymbolName: attention.symbolName, accessibilityDescription: attention.name)?
                .withSymbolConfiguration(configuration)
        else {
            return nil
        }
        guard alpha < 1 else {
            return symbol
        }
        let faded = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        faded.accessibilityDescription = attention.name
        return faded
    }
}

extension NSColor {
    /// This colour moved `amount` of the way to `other`, in sRGB.
    func mixed(with other: NSColor, by amount: CGFloat) -> NSColor {
        guard let from = usingColorSpace(.sRGB), let to = other.usingColorSpace(.sRGB) else {
            return self
        }
        let t = min(max(amount, 0), 1)
        return NSColor(
            srgbRed: from.redComponent + (to.redComponent - from.redComponent) * t,
            green: from.greenComponent + (to.greenComponent - from.greenComponent) * t,
            blue: from.blueComponent + (to.blueComponent - from.blueComponent) * t,
            alpha: 1
        )
    }
}
