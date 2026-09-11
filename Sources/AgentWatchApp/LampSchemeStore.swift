import AgentWatchCore
import AppKit

/// The lamp scheme as it is kept between launches.
///
/// One key per phase and per field, spelled out rather than nested, because the file is meant
/// to be read and corrected by hand: `lampColor.executing` says what it is without a legend.
/// A phase nobody has touched has no keys at all, which is what keeps the app's own lamp — a
/// system colour that follows the appearance of the machine — from being frozen into a
/// fixed one the first time the window is opened.
final class LampSchemeStore: PreferenceDefaults {
    private let preferences: PreferenceFile

    /// Told after every write, like the other preference stores.
    var onChange: ((WidgetSetting) -> Void)?

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    var scheme: LampScheme {
        var styles: [SessionPhase: LampStyle] = [:]
        for phase in SessionPhase.allCases {
            // A value that cannot be read falls back to the default rather than to a guess.
            // This file is meant to be corrected by hand, so a mistyped colour is a real
            // input, and the app's own is the honest answer to "this is not a colour".
            let color = preferences.string(forKey: Self.colorKey(phase)).flatMap(NSColor.init(hex:))
            let motion = preferences.string(forKey: Self.motionKey(phase))
                .flatMap(SessionLampAppearance.Motion.init(rawValue:))
            guard color != nil || motion != nil else {
                continue
            }
            let fallback = phase.defaultLampStyle
            styles[phase] = LampStyle(color: color ?? fallback.color, motion: motion ?? fallback.motion)
        }
        return LampScheme(styles: styles)
    }

    /// Every key this store owns, at its default value, for the first launch and for a reset.
    var defaultValues: [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for phase in SessionPhase.allCases {
            let style = phase.defaultLampStyle
            // A default colour is written from the same `#RRGGBB` the source file spells, so
            // the file a fresh install gets does not depend on the machine that wrote it.
            if let hex = style.color.srgbHex {
                values[Self.colorKey(phase)] = .string(hex)
            }
            values[Self.motionKey(phase)] = .string(style.motion.rawValue)
        }
        return values
    }

    func setColor(_ color: NSColor, for phase: SessionPhase) {
        guard let hex = color.srgbHex else {
            return
        }
        preferences.set(hex, forKey: Self.colorKey(phase))
        onChange?(.lampScheme)
    }

    func setMotion(_ motion: SessionLampAppearance.Motion, for phase: SessionPhase) {
        preferences.set(motion.rawValue, forKey: Self.motionKey(phase))
        onChange?(.lampScheme)
    }

    /// Back to the app's own lamp, every phase at once.
    ///
    /// Writes the defaults rather than removing the keys, because the file is meant to hold
    /// the whole scheme at all times: after a reset it says what the lamp is, in the same
    /// shape as before, and a person reading it never has to know which fields are missing
    /// and what the app would have done about them.
    func reset() {
        preferences.replace(defaultValues)
        onChange?(.lampScheme)
    }

    private static func colorKey(_ phase: SessionPhase) -> String {
        "lampColor.\(phase.rawValue)"
    }

    private static func motionKey(_ phase: SessionPhase) -> String {
        "lampMotion.\(phase.rawValue)"
    }
}

extension NSColor {
    /// `#RRGGBB`, or nothing when the colour cannot be resolved into one.
    ///
    /// The conversion is not optional politeness: a system colour is a catalog colour with no
    /// components of its own, and asking one for `redComponent` raises rather than returns.
    var srgbHex: String? {
        guard let color = usingColorSpace(.sRGB) else {
            return nil
        }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            channel(color.redComponent),
            channel(color.greenComponent),
            channel(color.blueComponent)
        )
    }

    /// Reads `#RRGGBB`, and nothing else. Written by this app and, when it goes wrong, by a
    /// person editing the file, so the only sensible answer to anything else is `nil`.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else {
            return nil
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
