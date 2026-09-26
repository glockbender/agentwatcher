import AgentWatchCore
import AppKit

/// The lamp scheme as it is kept between launches.
///
/// One key per phase and per field, spelled out rather than nested, because the file is meant
/// to be read and corrected by hand: `lampColor.executing` says what it is without a legend.
/// Missing fields use the phase's defaults, so an older file keeps its existing appearance.
final class LampSchemeStore: PreferenceDefaults {
    private let preferences: PreferenceFile

    /// Told after every write, like the other preference stores.
    var onChange: ((WidgetSetting) -> Void)?

    init(preferences: PreferenceFile) {
        self.preferences = preferences
        migrateAnimationSettings()
    }

    /// Convert the two old brightness modes before default seeding can hide their speed.
    /// The new cycle belongs to both animated modes; a chosen colour-fade period survives.
    private func migrateAnimationSettings() {
        var migrated: [String: JSONValue] = [:]
        for phase in SessionPhase.allCases {
            let motion = preferences.string(forKey: Self.motionKey(phase))
            let legacyDim = motion == "pulse" || motion == "urgent"
            if legacyDim {
                migrated[Self.motionKey(phase)] = .string("dim")
            }
            if preferences.number(forKey: Self.animationCycleKey(phase)) == nil {
                let oldCycle = preferences.number(forKey: "lampGradientCycle.\(phase.rawValue)")
                let cycle = legacyDim ? (motion == "urgent" ? 1.1 : 2.8) : oldCycle
                if let cycle, cycle.isFinite {
                    migrated[Self.animationCycleKey(phase)] = .number(Self.clampedCycle(cycle))
                }
            }
        }
        if !migrated.isEmpty { preferences.replace(migrated) }
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
            let fallback = phase.defaultLampStyle
            let gradientColor = preferences.string(forKey: Self.gradientColorKey(phase)).flatMap(NSColor.init(hex:))
            let cycle = preferences.number(forKey: Self.animationCycleKey(phase))
            styles[phase] = LampStyle(
                color: color ?? fallback.color, motion: motion ?? fallback.motion,
                gradientColor: gradientColor ?? fallback.gradientColor,
                animationCycle: cycle.flatMap { $0.isFinite ? Self.clampedCycle($0) : nil } ?? fallback.animationCycle
            )
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
            values[Self.gradientColorKey(phase)] = .string(style.gradientColor.srgbHex ?? "#FFFFFF")
            values[Self.animationCycleKey(phase)] = .number(style.animationCycle)
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

    func setGradientColor(_ color: NSColor, for phase: SessionPhase) {
        guard let hex = color.srgbHex else { return }
        preferences.set(hex, forKey: Self.gradientColorKey(phase))
        onChange?(.lampScheme)
    }

    func setAnimationCycle(_ seconds: TimeInterval, for phase: SessionPhase) {
        guard seconds.isFinite else { return }
        preferences.set(Self.clampedCycle(seconds), forKey: Self.animationCycleKey(phase))
        onChange?(.lampScheme)
    }

    private static func clampedCycle(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, LampStyle.animationCycleRange.lowerBound), LampStyle.animationCycleRange.upperBound)
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

    private static func gradientColorKey(_ phase: SessionPhase) -> String {
        "lampGradientColor.\(phase.rawValue)"
    }

    private static func animationCycleKey(_ phase: SessionPhase) -> String {
        "lampAnimationCycle.\(phase.rawValue)"
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
