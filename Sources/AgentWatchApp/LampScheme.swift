import AgentWatchCore
import AppKit

/// One phase's lamp: the two fields a person chooses.
struct LampStyle: Equatable {
    var color: NSColor
    var motion: SessionLampAppearance.Motion
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
    /// These are the values in use, chosen by the person this widget was built for. Five
    /// colours and three motions are theirs; the rest are the system colours as they resolved
    /// on a dark machine, which is what those phases already looked like.
    var defaultLampStyle: LampStyle {
        switch self {
        case .idle:
            LampStyle(color: NSColor(sRGB: "#98989D"), motion: .steady)
        case .planning:
            LampStyle(color: NSColor(sRGB: "#00EEEC"), motion: .pulse)
        case .executing:
            LampStyle(color: NSColor(sRGB: "#00FF5C"), motion: .pulse)
        case .waitingForChildren:
            LampStyle(color: NSColor(sRGB: "#6AC4DC"), motion: .pulse)
        case .waitingForUser:
            LampStyle(color: NSColor(sRGB: "#FF9F0A"), motion: .urgent)
        case .completed:
            LampStyle(color: NSColor(sRGB: "#CED4D0"), motion: .steady)
        case .failed:
            LampStyle(color: NSColor(sRGB: "#FF453A"), motion: .urgent)
        case .terminalClosed:
            // The failure's red, still. It is a failure a person has to deal with, but nothing
            // is lost by waiting, and a row like this can stand for days — blinking all that
            // time would be a nag, not news.
            LampStyle(color: NSColor(sRGB: "#FF453A"), motion: .steady)
        case .disconnected:
            LampStyle(color: NSColor(sRGB: "#BB7F7C"), motion: .pulse)
        case .sessionClosed:
            // `systemGray` as it resolves on a dark machine, like the rest of this table.
            // It was `#000000`, which is a black ring on a near-black widget: 1.6:1 against
            // the default background where every other phase reaches 4.6:1 or better. Being
            // the dimmest lamp is right for a session that has ended; being the one nobody
            // can see is not, and the shape already says it is over.
            LampStyle(color: NSColor(sRGB: "#8E8E93"), motion: .steady)
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
/// Only the colour and the motion. The shape — a ring for a session that has stopped
/// speaking — and the wording in the hover card stay the app's.
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
        }
    }
}

extension NSColor {
    /// A fixed colour from its `#RRGGBB` spelling, for the values written into this source
    /// file. Distinct from `init?(hex:)`, which reads what a person may have typed: a literal
    /// here is checked when the tests run, and a failure would mean this file is wrong.
    convenience init(sRGB hex: String) {
        guard let color = NSColor(hex: hex) else {
            preconditionFailure("not a colour: \(hex)")
        }
        self.init(
            srgbRed: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: 1
        )
    }
}
