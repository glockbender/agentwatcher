import AgentWatchCore
import AppKit

/// The row's indicator light: what a session is doing, in one dot.
///
/// Colour is never the only carrier, as `docs/architecture.md` §7 requires. Each phase also
/// has its own motion — still, a slow pulse, or an urgent blink — a closed session is drawn
/// as a ring rather than a disc, and the row's tooltip still spells the phase out in words.
struct SessionLampAppearance: Equatable {
    enum Motion: String, CaseIterable, Equatable {
        /// Nothing is happening and nothing is wrong.
        case steady
        /// Work in progress.
        case pulse
        /// Someone has to look at this session.
        case urgent

        /// What the settings window calls it. Describes what the dot does, not what it means:
        /// the meaning is the phase's, and one motion serves several phases.
        var title: String {
            switch self {
            case .steady: "Still"
            case .pulse: "Slow pulse"
            case .urgent: "Fast blink"
            }
        }
    }

    /// Settable because these two are the person's to choose; the shape and the wording are
    /// the app's. See `LampScheme`.
    var color: NSColor
    var motion: Motion
    /// A ring instead of a disc, for a session that has ended.
    let isFilled: Bool
    /// The wording the tooltip uses, since the dot itself cannot be read aloud.
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
        let isFilled =
            switch snapshot.phase {
            case .disconnected, .sessionClosed: false
            case .idle, .planning, .executing, .waitingForChildren, .waitingForUser, .completed, .failed: true
            }
        let name =
            switch snapshot.phase {
            case .idle: "idle"
            case .planning: "planning"
            case .executing: "working"
            case .waitingForChildren: "waiting for subtasks"
            case .waitingForUser: snapshot.userInputRequestKind == .selection ? "choice needed" : "approval needed"
            case .completed: "completed"
            case .failed: "failed"
            case .disconnected: "no signal"
            case .sessionClosed: "session closed"
            }
        return SessionLampAppearance(
            color: style.color,
            motion: style.motion,
            isFilled: isFilled,
            name: name
        )
    }
}

@MainActor
final class SessionLampView: NSView {
    static let diameter: CGFloat = 9

    private let look: SessionLampAppearance

    init(appearance: SessionLampAppearance) {
        look = appearance
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
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
        NSSize(width: Self.diameter, height: Self.diameter)
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

        layer.cornerRadius = Self.diameter / 2
        if look.isFilled {
            layer.backgroundColor = look.color.cgColor
            layer.borderWidth = 0
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
            // Heavier than a hairline: a ring has a fraction of a disc's area, and at nine
            // points a thin one disappears against a translucent widget.
            layer.borderWidth = 2
            layer.borderColor = look.color.cgColor
        }

        layer.removeAnimation(forKey: Self.blinkKey)
        switch look.motion {
        case .steady:
            layer.opacity = 1
        // Slow and shallow: a breath rather than a flash. Work in progress is the ordinary
        // state of this widget, and a lamp that demanded attention for it would leave
        // nothing to say with when a session actually wants something.
        case .pulse:
            // A ring needs a deeper breath than a disc for the same amount of movement to
            // register, for the same reason it needs a heavier border.
            blink(everySeconds: 1.4, downTo: look.isFilled ? 0.55 : 0.3)
        // Faster and deeper, because this one is asking to be noticed.
        case .urgent:
            blink(everySeconds: 0.55, downTo: 0.2)
        }
    }

    private static let blinkKey = "lamp"

    private func blink(everySeconds duration: TimeInterval, downTo dimmest: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = dimmest
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
