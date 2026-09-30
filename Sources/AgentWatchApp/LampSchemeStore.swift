import AgentWatchCore
import AppKit

/// The lamp colours as older versions kept them, one key per phase and field — read once, to
/// carry them into a theme of their own (`ThemeStore.adoptIfNeeded`).
///
/// One key per phase and per field, spelled out rather than nested, because the file is meant
/// to be read and corrected by hand: `lampColor.executing` says what it is without a legend.
/// Missing fields use the phase's defaults, so an older file keeps its existing appearance.
final class LampSchemeStore {
    private let preferences: PreferenceFile

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

    private static func clampedCycle(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, LampStyle.animationCycleRange.lowerBound), LampStyle.animationCycleRange.upperBound)
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

    /// Reads `#RRGGBB` or `#RRGGBBAA`, and nothing else. Written by this app and, when it goes wrong, by a
    /// person editing the file, so the only sensible answer to anything else is `nil`.
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = Int(digits, radix: 16) else {
            return nil
        }
        let rgb = digits.count == 8 ? value >> 8 : value
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: digits.count == 8 ? CGFloat(value & 0xFF) / 255 : 1
        )
    }
}
