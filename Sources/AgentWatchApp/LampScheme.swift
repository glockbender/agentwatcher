import AgentWatchCore
import AppKit

/// One phase's lamp, including the colour endpoints and animation period.
struct LampStyle: Equatable {
    var color: NSColor
    var motion: SessionLampAppearance.Motion
    var gradientColor: NSColor = NSColor(sRGB: "#FFFFFF")
    /// A full dim/bright or colour round trip, in seconds.
    var animationCycle: TimeInterval = 2.8

    static let animationCycleRange: ClosedRange<Double> = 0.5...10
}

extension SessionPhase {
    /// The lamp this phase gets when nobody has chosen anything.
    ///
    /// Written as fixed values rather than as `NSColor.systemBlue` and friends, and the
    /// reason is measurable: a system colour adapts to the machine's light or dark
    /// appearance — `systemBlue` is `#0A84FF` in one and `#007AFF` in the other — but the
    /// lamp is not drawn on a system surface. It sits on the widget's own background, one of
    /// ten fixed colours the person picks, half of them light. So the adaptation was tracking
    /// a surface the dot never touches, while making the shipped default depend on the state
    /// of the machine that first wrote the settings file.
    ///
    /// These are the values in use, copied on 2026-09-26 from the settings of the person this
    /// widget was built for, and chosen together with the blue default background. Stored
    /// preferences still win; new installations and Reset use this table.
    ///
    /// Six phases fall below 3:1 against that blue: its brightness is close to theirs. That
    /// was accepted, not missed — colour is never the only carrier of a phase (ADR-0003),
    /// and this is the palette its owner reads every day. `LampSchemeTests` names the six,
    /// so adding a seventh has to be a decision too.
    var defaultLampStyle: LampStyle {
        switch self {
        case .idle:
            LampStyle(
                color: NSColor(sRGB: "#98989D"), motion: .steady,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 2.8)
        case .planning:
            LampStyle(
                color: NSColor(sRGB: "#00EEEC"), motion: .dim,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 1.5)
        case .executing:
            LampStyle(
                color: NSColor(sRGB: "#00FF5C"), motion: .dim,
                gradientColor: NSColor(sRGB: "#00A900"), animationCycle: 2.5)
        case .waitingForChildren:
            LampStyle(
                color: NSColor(sRGB: "#6AC4DC"), motion: .dim,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 3)
        case .waitingForUser:
            LampStyle(
                color: NSColor(sRGB: "#FF9F0A"), motion: .gradient,
                gradientColor: NSColor(sRGB: "#FFFB00"), animationCycle: 0.5)
        case .completed:
            LampStyle(
                color: NSColor(sRGB: "#CED4D0"), motion: .steady,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 2.8)
        case .rateLimited:
            LampStyle(
                color: NSColor(sRGB: "#BF9BFA"), motion: .dim,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 2)
        case .failed:
            LampStyle(
                color: NSColor(sRGB: "#FF453A"), motion: .dim,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 1)
        case .terminalClosed:
            // The failure's red, still. It is a failure a person has to deal with, but nothing
            // is lost by waiting, and a row like this can stand for days — blinking all that
            // time would be a nag, not news.
            LampStyle(
                color: NSColor(sRGB: "#FF453A"), motion: .steady,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 2.8)
        case .disconnected:
            LampStyle(
                color: NSColor(sRGB: "#BB7F7C"), motion: .dim,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 2.8)
        case .sessionClosed:
            // Black, and it works only because the default background is blue: 3.46:1 there,
            // where the grey `#8E8E93` it replaced reaches 1.86:1. On Graphite black falls to
            // 1.35:1 and the ring cannot be seen. No grey serves both, so the default
            // background decides; the ring shape still says that the session is over.
            LampStyle(
                color: NSColor(sRGB: "#000000"), motion: .steady,
                gradientColor: NSColor(sRGB: "#FFFFFF"), animationCycle: 2.8)
        }
    }
}

/// The lamp, phase by phase, as it is going to be drawn.
///
/// Complete by construction: every phase has a colour and a motion, and anything the stored
/// file does not say is filled from `defaultLampStyle` on the way in. That is what makes
/// "every field is written" true by type rather than by discipline — there is no half-set
/// phase to reason about, and no optional to answer for at the drawing end.
///
/// Colours, motion and fade period. The shape — disc, ring or pause — and the wording
/// in the hover card stay the app's.
struct LampScheme: Equatable {
    private var styles: [SessionPhase: LampStyle]

    /// - Parameter styles: what the file said. Phases it did not mention take the default.
    init(styles: [SessionPhase: LampStyle] = [:]) {
        self.styles = Dictionary(
            uniqueKeysWithValues: SessionPhase.allCases.map { phase in
                (phase, styles[phase] ?? phase.defaultLampStyle)
            }
        )
    }

    func style(for phase: SessionPhase) -> LampStyle {
        // The initialiser fills every phase, so the fallback is unreachable rather than a
        // decision — stated here because a dictionary cannot promise it in the type.
        styles[phase] ?? phase.defaultLampStyle
    }

    mutating func setColor(_ color: NSColor, for phase: SessionPhase) {
        styles[phase]?.color = color
    }

    mutating func setMotion(_ motion: SessionLampAppearance.Motion, for phase: SessionPhase) {
        styles[phase]?.motion = motion
    }

    var isDefault: Bool {
        SessionPhase.allCases.allSatisfy { phase in
            let style = style(for: phase)
            let fallback = phase.defaultLampStyle
            return style.motion == fallback.motion && style.color.srgbHex == fallback.color.srgbHex
                && style.gradientColor.srgbHex == fallback.gradientColor.srgbHex
                && style.animationCycle == fallback.animationCycle
        }
    }
}
