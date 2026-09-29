import AgentWatchCore
import AppKit

/// Every colour and animation the widget and the sphere are drawn with, for light and for dark.
///
/// One file per theme in the `Themes` folder, so a theme can be shared, edited by hand, or
/// written by somebody else. Anything a file leaves out or gets wrong is taken from `standard`.
struct WidgetTheme: Codable, Equatable {
    var name: String
    var light: Look
    var dark: Look

    struct Look: Codable, Equatable {
        /// `#RRGGBB`.
        var background: String
        /// By phase, as `SessionPhase` spells it.
        var lamps: [String: Lamp]
        /// The menu bar's marks, by state, as `SessionAttention` spells it.
        var attention: [String: String]
        /// The widget's other marks, by `WidgetTheme.Role`.
        var colors: [String: String]

        init(
            background: String, lamps: [String: Lamp], attention: [String: String] = WidgetTheme.attention,
            colors: [String: String] = WidgetTheme.colors
        ) {
            self.background = background
            self.lamps = lamps
            self.attention = attention
            self.colors = colors
        }

        /// A file may leave anything out: what is missing is the built-in theme's.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            background = try values.decodeIfPresent(String.self, forKey: .background) ?? "#006996"
            lamps = try values.decodeIfPresent([String: Lamp].self, forKey: .lamps) ?? [:]
            attention = try values.decodeIfPresent([String: String].self, forKey: .attention) ?? [:]
            colors = try values.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        }
    }

    struct Lamp: Codable, Equatable {
        var color: String
        var motion: String
        var fadeTo: String
        var cycle: Double
    }

    static let attention: [String: String] = [
        SessionAttention.needsPerson.rawValue: "#FF9F0A",
        SessionAttention.working.rawValue: "#0A85FF",
        SessionAttention.done.rawValue: "#30D159",
        SessionAttention.quiet.rawValue: "#9E9E9E",
    ]

    enum Role: String, CaseIterable {
        /// A timer on a session that has gone quiet, and one that has been silent too long.
        case timerQuiet, timerStale
        /// The outline that flashes when the widget is shown.
        case highlight
    }

    static let colors: [String: String] = [
        Role.timerQuiet.rawValue: "#FFD60A",
        Role.timerStale.rawValue: "#FF9F0A",
        Role.highlight.rawValue: "#FF9F0A",
    ]

    /// The look in use, for the few drawings that cannot be handed one: the menu bar's marks.
    /// Set whenever the theme or the system's appearance changes.
    nonisolated(unsafe) static var active: Look = standard.dark

    static let standard = WidgetTheme(
        name: "Default",
        light: Look(background: "#E3EAF2", lamps: lamps(from: LampScheme())),
        dark: Look(background: "#006996", lamps: lamps(from: LampScheme()))
    )

    static func lamps(from scheme: LampScheme) -> [String: Lamp] {
        Dictionary(
            uniqueKeysWithValues: SessionPhase.allCases.map { phase in
                let style = scheme.style(for: phase)
                return (
                    phase.rawValue,
                    Lamp(
                        color: style.color.srgbHex ?? "#FFFFFF",
                        motion: style.motion.rawValue,
                        fadeTo: style.gradientColor.srgbHex ?? "#FFFFFF",
                        cycle: style.animationCycle
                    )
                )
            })
    }

    func look(dark isDark: Bool) -> Look {
        isDark ? dark : light
    }
}

extension WidgetTheme.Look {
    func color(_ role: WidgetTheme.Role) -> NSColor {
        colors[role.rawValue].flatMap(NSColor.init(hex:))
            ?? WidgetTheme.colors[role.rawValue].flatMap(NSColor.init(hex:)) ?? .gray
    }

    func accent(for attention: SessionAttention) -> NSColor {
        self.attention[attention.rawValue].flatMap(NSColor.init(hex:))
            ?? WidgetTheme.attention[attention.rawValue].flatMap(NSColor.init(hex:)) ?? .gray
    }

    var widgetBackground: WidgetBackground {
        NSColor(hex: background).flatMap(WidgetBackground.init(custom:)) ?? .defaultBackground
    }

    var lampScheme: LampScheme {
        var styles: [SessionPhase: LampStyle] = [:]
        for phase in SessionPhase.allCases {
            let fallback = phase.defaultLampStyle
            guard let lamp = lamps[phase.rawValue] else {
                continue
            }
            styles[phase] = LampStyle(
                color: NSColor(hex: lamp.color) ?? fallback.color,
                motion: SessionLampAppearance.Motion(rawValue: lamp.motion) ?? fallback.motion,
                gradientColor: NSColor(hex: lamp.fadeTo) ?? fallback.gradientColor,
                animationCycle: lamp.cycle.isFinite
                    ? min(
                        max(lamp.cycle, LampStyle.animationCycleRange.lowerBound),
                        LampStyle.animationCycleRange.upperBound)
                    : fallback.animationCycle
            )
        }
        return LampScheme(styles: styles)
    }
}

enum ThemeMode: String, CaseIterable {
    case auto, light, dark

    var name: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Which theme is in use, in which mode, and the themes on offer: the built-in one and every
/// file in the `Themes` folder.
final class ThemeStore: PreferenceDefaults {
    private enum Key {
        static let theme = "theme"
        static let mode = "themeMode"
    }

    private let preferences: PreferenceFile
    let folder: URL?
    var onChange: ((WidgetSetting) -> Void)?
    /// The files that could not be read, by name, with what was wrong.
    private(set) var problems: [String] = []
    private(set) var themes: [WidgetTheme] = [.standard]

    init(preferences: PreferenceFile, folder: URL?) {
        self.preferences = preferences
        self.folder = folder
        reload()
    }

    var defaultValues: [String: JSONValue] {
        [Key.theme: .string(WidgetTheme.standard.name), Key.mode: .string(ThemeMode.auto.rawValue)]
    }

    var theme: WidgetTheme {
        let name = preferences.string(forKey: Key.theme)
        return themes.first { $0.name == name } ?? .standard
    }

    var mode: ThemeMode {
        preferences.string(forKey: Key.mode).flatMap(ThemeMode.init(rawValue:)) ?? .auto
    }

    @MainActor var isDark: Bool {
        switch mode {
        case .light: false
        case .dark: true
        case .auto: NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    @MainActor var look: WidgetTheme.Look {
        theme.look(dark: isDark)
    }

    /// What the widget is drawn for. On glass the desktop, not the theme's colour, is behind the
    /// text, so the text follows light and dark mode as the Dock's labels do.
    @MainActor func widgetBackground(on material: WidgetMaterial) -> WidgetBackground {
        guard material.drawn.needsLiquidGlass else {
            return look.widgetBackground
        }
        return isDark ? .graphite : .pearl
    }

    func select(_ theme: WidgetTheme) {
        preferences.set(theme.name, forKey: Key.theme)
        onChange?(.theme)
    }

    func select(_ mode: ThemeMode) {
        preferences.set(mode.rawValue, forKey: Key.mode)
        onChange?(.theme)
    }

    /// Reads the folder again: a theme dropped in, edited or removed is picked up.
    func reload() {
        problems = []
        var found: [WidgetTheme] = [.standard]
        let files = folder.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        for file in (files ?? []).filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            do {
                var theme = try JSONDecoder().decode(WidgetTheme.self, from: Data(contentsOf: file))
                if theme.name == WidgetTheme.standard.name {
                    theme.name += " (file)"
                }
                found.append(theme)
            } catch {
                problems.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        themes = found
    }

    /// A copy of the theme in use, as a file of its own, selected — the way to start editing.
    @discardableResult
    func duplicate() -> URL? {
        var copy = theme
        let taken = Set(themes.map(\.name))
        copy.name = "\(theme.name) copy"
        var number = 2
        while taken.contains(copy.name) {
            copy.name = "\(theme.name) copy \(number)"
            number += 1
        }
        guard let url = write(copy) else {
            return nil
        }
        reload()
        select(copy)
        return url
    }

    /// Before the first theme is chosen, whatever colours were set by hand become a theme of
    /// their own, in use, so nobody's widget changes colour on update.
    func adoptIfNeeded(lampScheme: LampScheme, background: WidgetBackground) {
        guard preferences.string(forKey: Key.theme) == nil else {
            return
        }
        let lamps = WidgetTheme.lamps(from: lampScheme)
        let hex = background.color.srgbHex ?? "#006996"
        guard lamps != WidgetTheme.standard.dark.lamps || hex != WidgetTheme.standard.dark.background else {
            return
        }
        let mine = WidgetTheme(
            name: "My Theme",
            light: WidgetTheme.Look(background: hex, lamps: lamps),
            dark: WidgetTheme.Look(background: hex, lamps: lamps)
        )
        guard write(mine) != nil else {
            return
        }
        reload()
        preferences.replace([Key.theme: .string(mine.name), Key.mode: .string(ThemeMode.auto.rawValue)])
    }

    private func write(_ theme: WidgetTheme) -> URL? {
        guard let folder else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = folder.appendingPathComponent("\(theme.name).json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(theme).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
