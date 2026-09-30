import AgentWatchCore
import AppKit

/// The row's indicator light: what a session is doing, in one dot.
///
/// Colour is never the only carrier, as ADR-0003 requires. Each phase also
/// has its own motion — still, a slow pulse, or an urgent blink — a closed session is drawn
/// as a ring rather than a disc, a rate limit as a pause, and the hover card names each phase.
struct SessionLampAppearance: Equatable {
    enum Motion: String, CaseIterable, Equatable {
        /// The lamp holds its colour.
        case steady
        /// A smooth change in brightness.
        case dim
        /// A smooth trip between two colours, without fading the lamp away.
        case gradient

        /// What the settings window calls it. Describes what the dot does, not what it means:
        /// the meaning is the phase's, and one motion serves several phases.
        var title: String {
            switch self {
            case .steady: "None"
            case .dim: "Dim"
            case .gradient: "Two-color fade"
            }
        }
    }

    /// Settable because the appearance is the person's to choose; the shape and wording are
    /// the app's. See `LampScheme`.
    var color: NSColor
    var motion: Motion
    var gradientColor: NSColor = NSColor(sRGB: "#FFFFFF")
    var animationCycle: TimeInterval = 2.8
    enum Shape: Equatable {
        case disc
        case ring
        case pause
    }

    let shape: Shape
    var isFilled: Bool { shape != .ring }
    /// The wording the card and the settings window use, since a dot cannot be read aloud.
    let name: String
}

@MainActor
enum SessionLamp {
    /// The lamp for a session, drawn with the scheme in force.
    static func appearance(for snapshot: SessionSnapshot, scheme: LampScheme) -> SessionLampAppearance {
        var look = builtInAppearance(for: snapshot)
        let style = scheme.style(for: snapshot.phase)
        look.color = style.color
        look.motion = style.motion
        look.gradientColor = style.gradientColor
        look.animationCycle = style.animationCycle
        return look
    }

    /// The lamp as the app draws it when nothing has been changed.
    ///
    /// The colour and the motion come from `SessionPhase.defaultLampStyle`, which is also
    /// what gets written into the settings file — one table, so the file and the drawing
    /// cannot disagree. What is left here is the half a person cannot change: the shape, and
    /// the wording the hover card reads out.
    static func builtInAppearance(for snapshot: SessionSnapshot) -> SessionLampAppearance {
        let style = snapshot.phase.defaultLampStyle
        // A ring for a session that has stopped speaking, a disc for one that has not. This
        // is what keeps the dot from depending on its colour: `no signal` pulses like live
        // work because it may still come back, while a closed session is still.
        let shape: SessionLampAppearance.Shape =
            switch snapshot.phase {
            case .disconnected, .sessionClosed: .ring
            case .rateLimited: .pause
            case .idle, .planning, .executing, .waitingForChildren, .waitingForUser, .completed, .failed,
                .terminalClosed:
                .disc
            }
        let name =
            switch snapshot.phase {
            case .idle: "idle"
            case .planning: "planning"
            case .executing: "working"
            case .waitingForChildren: "waiting for subtasks"
            case .waitingForUser: snapshot.userInputRequestKind == .selection ? "choice needed" : "approval needed"
            case .completed: "completed"
            case .rateLimited: "limit reached"
            case .failed: "failed"
            case .terminalClosed: "terminal closed"
            case .disconnected: "no signal"
            case .sessionClosed: "session closed"
            }
        return SessionLampAppearance(
            color: style.color,
            motion: style.motion,
            gradientColor: style.gradientColor,
            animationCycle: style.animationCycle,
            shape: shape,
            name: name
        )
    }
}

@MainActor
final class SessionLampView: NSView {
    private let look: SessionLampAppearance
    /// Given rather than fixed, so the lamp grows with the row it sits in — the ring's border
    /// below is the one part of the drawing that does not, and says why.
    private let diameter: CGFloat

    init(appearance: SessionLampAppearance, diameter: CGFloat) {
        look = appearance
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: diameter, height: diameter)
    }

    /// Painted again on joining a window, and again whenever the backing store changes.
    ///
    /// A view that joins a layer-backed hierarchy — everything under the widget's visual
    /// effect view is one — can be handed a fresh backing layer, and everything set on the
    /// old one goes with it, the repeating animation included. That is why the lamp appeared
    /// to blink only when a row was rebuilt: each rebuild started an animation that the next
    /// layer swap threw away, so what showed was the rebuild, not the blink.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            return
        }
        paint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        paint()
    }

    private func paint() {
        guard let layer else {
            return
        }

        layer.cornerRadius = look.shape == .pause ? 0 : diameter / 2
        layer.mask = nil
        if look.shape == .pause {
            let path = CGMutablePath()
            for x in [diameter * 0.15, diameter * 0.6] {
                path.addRoundedRect(
                    in: CGRect(x: x, y: diameter * 0.05, width: diameter * 0.25, height: diameter * 0.9),
                    cornerWidth: diameter * 0.06, cornerHeight: diameter * 0.06
                )
            }
            let mask = CAShapeLayer()
            mask.path = path
            layer.mask = mask
        }
        if look.isFilled {
            layer.backgroundColor = look.color.cgColor
            layer.borderWidth = 0
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
            // Heavier than a hairline: a ring has a fraction of a disc's area, and at nine
            // points a thin one disappears against a translucent widget. Two points at every
            // scale, and deliberately: what this number is avoiding is a border so thin it
            // vanishes, which only happens at the small end.
            layer.borderWidth = 2
            layer.borderColor = look.color.cgColor
        }

        layer.removeAnimation(forKey: Self.blinkKey)
        layer.opacity = 1
        switch look.motion {
        case .steady:
            break
        case .gradient:
            guard look.color.srgbHex != look.gradientColor.srgbHex else { return }
            let animation = CABasicAnimation(keyPath: look.isFilled ? "backgroundColor" : "borderColor")
            animation.fromValue = look.color.cgColor
            animation.toValue = look.gradientColor.cgColor
            animate(animation, everySeconds: look.animationCycle / 2)
        case .dim:
            // A ring needs a deeper fade than a disc for the movement to register.
            blink(
                everySeconds: look.animationCycle / 2,
                downTo: Float(
                    look.isFilled ? ThemeInUse.timing.widget.lampDimDisc : ThemeInUse.timing.widget.lampDimRing))
        }
    }

    private static let blinkKey = "lamp"

    private func blink(everySeconds duration: TimeInterval, downTo dimmest: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = dimmest
        animate(animation, everySeconds: duration)
    }

    private func animate(_ animation: CABasicAnimation, everySeconds duration: TimeInterval) {
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        // The whole list is rebuilt every couple of seconds, and a fresh animation would
        // restart its cycle each time — every lamp would jump instead of pulsing. Anchoring
        // the start to a whole number of cycles on the shared media clock makes a new lamp
        // pick the blink up exactly where the one it replaces left off.
        let cycle = 2 * duration
        let clock = CACurrentMediaTime()
        animation.beginTime = clock - clock.truncatingRemainder(dividingBy: cycle)
        layer?.add(animation, forKey: Self.blinkKey)
    }

    /// Whether the lamp is currently animating, for a test that cannot see the screen.
    var isBlinking: Bool {
        layer?.animation(forKey: Self.blinkKey) != nil
    }

    /// The colour actually on the layer, not the one it was asked for.
    ///
    /// A disc carries it as a fill and a ring as a border, and reading the appearance the
    /// view was built with would prove only that the value was stored.
    var paintedColor: NSColor? {
        guard let painted = look.isFilled ? layer?.backgroundColor : layer?.borderColor else {
            return nil
        }
        return NSColor(cgColor: painted)
    }
}
