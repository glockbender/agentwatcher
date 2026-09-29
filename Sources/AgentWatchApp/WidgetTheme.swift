import AgentWatchCore
import AppKit

/// Every colour and animation the widget, the menu bar and the menu are drawn with, for light
/// and for dark.
///
/// One file per theme in the `Themes` folder, so a theme can be shared, edited by hand, or
/// written by somebody else. Anything a file leaves out or gets wrong is taken from `standard`,
/// and every field a later version adds reads as what the screen showed before it existed — so
/// an older file looks the same after an update (ADR-0017).
struct WidgetTheme: Codable, Equatable {
    var name: String
    var light: Look
    var dark: Look

    init(name: String, light: Look, dark: Look) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    /// A look the file leaves out is the built-in theme's, like anything else it leaves out.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Theme"
        light = try values.decodeIfPresent(Look.self, forKey: .light) ?? Self.standard.light
        dark = try values.decodeIfPresent(Look.self, forKey: .dark) ?? Self.standard.dark
    }

    struct Look: Codable, Equatable {
        /// `#RRGGBB`.
        var background: String
        /// What the widget's panel is made of, as `WidgetMaterial` spells it.
        var material: String
        /// How much of the panel's colour is drawn, within `WidgetTheme.opacityRange`.
        var opacity: Double
        /// By phase, as `SessionPhase` spells it.
        var lamps: [String: Lamp]
        /// Each state's own colour, by state as `SessionAttention` spells it: the menu bar's
        /// marks, the menu's, and the widget's counter of hidden sessions that need you.
        var attention: [String: String]
        /// A state that takes its colour from a lamp instead: state → phase. Only a phase of
        /// that state counts (`SessionPhase.attention`); anything else leaves the state's own.
        var attentionLamps: [String: String]
        /// How each state's mark moves, in the menu bar's grid and in the menu.
        var attentionMotion: [String: Motion]
        /// The widget's other marks, by `WidgetTheme.Role`.
        var colors: [String: String]
        var menu: Menu
        var sphere: Sphere

        init(
            background: String,
            material: WidgetMaterial = .glass,
            opacity: Double = WidgetTheme.defaultOpacity,
            lamps: [String: Lamp],
            attention: [String: String] = WidgetTheme.attention,
            attentionLamps: [String: String] = [:],
            attentionMotion: [String: Motion] = WidgetTheme.attentionMotion,
            colors: [String: String] = WidgetTheme.colors,
            menu: Menu = Menu(),
            sphere: Sphere = Sphere()
        ) {
            self.background = background
            self.material = material.rawValue
            self.opacity = opacity
            self.lamps = lamps
            self.attention = attention
            self.attentionLamps = attentionLamps
            self.attentionMotion = attentionMotion
            self.colors = colors
            self.menu = menu
            self.sphere = sphere
        }

        /// A file may leave anything out: what is missing is the built-in theme's.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            background = try values.decodeIfPresent(String.self, forKey: .background) ?? "#006996"
            material = try values.decodeIfPresent(String.self, forKey: .material) ?? WidgetMaterial.glass.rawValue
            opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? WidgetTheme.defaultOpacity
            lamps = try values.decodeIfPresent([String: Lamp].self, forKey: .lamps) ?? [:]
            attention = try values.decodeIfPresent([String: String].self, forKey: .attention) ?? [:]
            attentionLamps = try values.decodeIfPresent([String: String].self, forKey: .attentionLamps) ?? [:]
            attentionMotion = try values.decodeIfPresent([String: Motion].self, forKey: .attentionMotion) ?? [:]
            colors = try values.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
            menu = try values.decodeIfPresent(Menu.self, forKey: .menu) ?? Menu()
            sphere = try values.decodeIfPresent(Sphere.self, forKey: .sphere) ?? Sphere()
        }
    }

    struct Lamp: Codable, Equatable {
        var color: String
        var motion: String
        var fadeTo: String
        var cycle: Double
    }

    /// A mark's movement, the way a lamp's is described: `steady`, `dim` or `gradient`, the
    /// colour a `gradient` goes to, and one full round trip in seconds.
    struct Motion: Codable, Equatable {
        var motion: String
        var fadeTo: String
        var cycle: Double

        init(motion: SessionLampAppearance.Motion, fadeTo: String = "#FFFFFF", cycle: Double) {
            self.motion = motion.rawValue
            self.fadeTo = fadeTo
            self.cycle = cycle
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            motion =
                try values.decodeIfPresent(String.self, forKey: .motion) ?? SessionLampAppearance.Motion.steady.rawValue
            fadeTo = try values.decodeIfPresent(String.self, forKey: .fadeTo) ?? "#FFFFFF"
            cycle = try values.decodeIfPresent(Double.self, forKey: .cycle) ?? WidgetTheme.markCycle
        }
    }

    /// What colours the menu's session lines and how they move.
    struct Menu: Codable, Equatable {
        /// `state`: the colour of the line's state, as in the menu bar. `lamp`: the line's own
        /// session's lamp, as in its row in the widget.
        var colors: String = MenuColors.state.rawValue
        /// `none`, `state` for the state's movement, or `lamp` for the session's lamp's.
        var motion: String = MenuMotion.none.rawValue

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            colors = try values.decodeIfPresent(String.self, forKey: .colors) ?? MenuColors.state.rawValue
            motion = try values.decodeIfPresent(String.self, forKey: .motion) ?? MenuMotion.none.rawValue
        }
    }

    enum MenuColors: String, CaseIterable {
        case state, lamp
    }

    enum MenuMotion: String, CaseIterable {
        case none, state, lamp
    }

    /// The sphere's own movements. Nothing in a lamp maps onto a ball of blended colours, so
    /// they are the sphere's alone; the defaults are the ones ADR-0015 records.
    struct Sphere: Codable, Equatable {
        /// A halo in the colour of the most important state the sphere holds.
        var halo = true
        /// Whether the halo breathes while a session needs you, and over how long.
        var haloBreathes = true
        var haloCycle: Double = 4
        /// The colours swaying under the light while anything works or needs you.
        var sway = true
        var swayDegrees: Double = 35
        var swayCycle: Double = 7
        /// One swell when a count changes.
        var swell = true
        var swellSeconds: Double = 1.6

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let standard = Sphere()
            halo = try values.decodeIfPresent(Bool.self, forKey: .halo) ?? standard.halo
            haloBreathes = try values.decodeIfPresent(Bool.self, forKey: .haloBreathes) ?? standard.haloBreathes
            haloCycle = try values.decodeIfPresent(Double.self, forKey: .haloCycle) ?? standard.haloCycle
            sway = try values.decodeIfPresent(Bool.self, forKey: .sway) ?? standard.sway
            swayDegrees = try values.decodeIfPresent(Double.self, forKey: .swayDegrees) ?? standard.swayDegrees
            swayCycle = try values.decodeIfPresent(Double.self, forKey: .swayCycle) ?? standard.swayCycle
            swell = try values.decodeIfPresent(Bool.self, forKey: .swell) ?? standard.swell
            swellSeconds = try values.decodeIfPresent(Double.self, forKey: .swellSeconds) ?? standard.swellSeconds
        }

        static let haloCycleRange: ClosedRange<Double> = 1...10
        static let swayDegreesRange: ClosedRange<Double> = 5...90
        static let swayCycleRange: ClosedRange<Double> = 2...20
        static let swellSecondsRange: ClosedRange<Double> = 0.4...4

        /// Every number held inside the range the editor offers, whatever a file says.
        var clamped: Sphere {
            var sphere = self
            sphere.haloCycle = haloCycle.clamped(to: Self.haloCycleRange, or: Sphere().haloCycle)
            sphere.swayDegrees = swayDegrees.clamped(to: Self.swayDegreesRange, or: Sphere().swayDegrees)
            sphere.swayCycle = swayCycle.clamped(to: Self.swayCycleRange, or: Sphere().swayCycle)
            sphere.swellSeconds = swellSeconds.clamped(to: Self.swellSecondsRange, or: Sphere().swellSeconds)
            return sphere
        }
    }

    static let defaultOpacity: Double = 0.82
    /// Not zero: an invisible widget cannot be found again by the person who made it
    /// invisible. At five percent it is already glass, and `Highlight Widget` can still point
    /// at it.
    static let opacityRange: ClosedRange<Double> = 0.05...1

    static let attention: [String: String] = [
        SessionAttention.needsPerson.rawValue: "#FF9F0A",
        SessionAttention.working.rawValue: "#0A85FF",
        SessionAttention.done.rawValue: "#30D159",
        SessionAttention.quiet.rawValue: "#9E9E9E",
    ]

    /// The one rhythm the menu bar's grid has always breathed at, for both states that breathe.
    static let markCycle: Double = 1.4

    /// The grid as it shipped: needs you and working breathe, done and idle hold still.
    static let attentionMotion: [String: Motion] = [
        SessionAttention.needsPerson.rawValue: Motion(motion: .dim, cycle: markCycle),
        SessionAttention.working.rawValue: Motion(motion: .dim, cycle: markCycle),
        SessionAttention.done.rawValue: Motion(motion: .steady, cycle: markCycle),
        SessionAttention.quiet.rawValue: Motion(motion: .steady, cycle: markCycle),
    ]

    enum Role: String, CaseIterable {
        /// A timer on a session that has gone quiet, and one that has been silent too long.
        case timerQuiet, timerStale
        /// The outline that flashes when the widget is shown.
        case highlight

        var name: String {
            switch self {
            case .timerQuiet: "Timer, quiet"
            case .timerStale: "Timer, silent too long"
            case .highlight: "Highlight outline"
            }
        }
    }

    static let colors: [String: String] = [
        Role.timerQuiet.rawValue: "#FFD60A",
        Role.timerStale.rawValue: "#FF9F0A",
        Role.highlight.rawValue: "#FF9F0A",
    ]

    /// The look in use, for the few drawings that cannot be handed one: the menu bar's marks,
    /// the menu's and the counter's. Set whenever the theme or the system's appearance changes.
    nonisolated(unsafe) static var active: Look = standard.dark

    static let standard = WidgetTheme(
        name: "Default",
        light: Look(background: "#E3EAF2", lamps: lamps(from: LampScheme())),
        dark: Look(background: "#006996", lamps: lamps(from: LampScheme()))
    )

    static func lamps(from scheme: LampScheme) -> [String: Lamp] {
        Dictionary(
            uniqueKeysWithValues: SessionPhase.allCases.map { phase in
                (phase.rawValue, Lamp(scheme.style(for: phase)))
            })
    }

    func look(dark isDark: Bool) -> Look {
        isDark ? dark : light
    }
}

extension WidgetTheme.Lamp {
    init(_ style: LampStyle) {
        self.init(
            color: style.color.srgbHex ?? "#FFFFFF",
            motion: style.motion.rawValue,
            fadeTo: style.gradientColor.srgbHex ?? "#FFFFFF",
            cycle: style.animationCycle
        )
    }
}

extension SessionAttention {
    /// The phases whose lamp can stand for this state in the menu bar: the ones that count
    /// towards it. `closed` is counted nowhere and has none.
    var phases: [SessionPhase] {
        SessionPhase.allCases.filter { $0.attention == self }
    }

    /// The lamp that stands for the state when it is told to take one: the phase a session in
    /// that state is most often in.
    var leadPhase: SessionPhase? {
        switch self {
        case .needsPerson: .waitingForUser
        case .working: .executing
        case .done: .completed
        case .quiet: .idle
        case .closed: nil
        }
    }
}

extension WidgetTheme.Look {
    func color(_ role: WidgetTheme.Role) -> NSColor {
        colors[role.rawValue].flatMap(NSColor.init(hex:))
            ?? WidgetTheme.colors[role.rawValue].flatMap(NSColor.init(hex:)) ?? .gray
    }

    mutating func setColor(_ colour: NSColor, for role: WidgetTheme.Role) {
        colors[role.rawValue] = colour.srgbHex ?? colors[role.rawValue]
    }

    /// The state's colour as it is drawn: its lamp's when it follows one, its own otherwise.
    func accent(for attention: SessionAttention) -> NSColor {
        if let phase = lamp(for: attention) {
            return lampScheme.style(for: phase).color
        }
        return ownAccent(for: attention)
    }

    /// The state's own colour, whether or not it follows a lamp at the moment — what the
    /// editor shows under the switch, and what the state goes back to.
    func ownAccent(for attention: SessionAttention) -> NSColor {
        self.attention[attention.rawValue].flatMap(NSColor.init(hex:))
            ?? WidgetTheme.attention[attention.rawValue].flatMap(NSColor.init(hex:)) ?? .gray
    }

    mutating func setOwnAccent(_ colour: NSColor, for attention: SessionAttention) {
        self.attention[attention.rawValue] = colour.srgbHex ?? self.attention[attention.rawValue]
    }

    /// The phase whose lamp the state takes its colour from, if it takes one at all.
    func lamp(for attention: SessionAttention) -> SessionPhase? {
        guard let phase = attentionLamps[attention.rawValue].flatMap(SessionPhase.init(rawValue:)),
            phase.attention == attention
        else {
            return nil
        }
        return phase
    }

    mutating func setLamp(_ phase: SessionPhase?, for attention: SessionAttention) {
        attentionLamps[attention.rawValue] = phase.flatMap { $0.attention == attention ? $0.rawValue : nil }
    }

    /// Whether every state shown in the menu bar takes a lamp's colour, and the menu's lines
    /// their own session's lamp: the one switch for a person who wants everything to match.
    var followsLamps: Bool {
        SessionAttention.counted.allSatisfy { lamp(for: $0) != nil } && menuColors == .lamp
    }

    mutating func setFollowsLamps(_ follows: Bool) {
        for attention in SessionAttention.counted {
            setLamp(follows ? (lamp(for: attention) ?? attention.leadPhase) : nil, for: attention)
        }
        menuColors = follows ? .lamp : .state
    }

    /// The state's mark as the grid and the menu draw it: its colour and how it moves.
    func markStyle(for attention: SessionAttention) -> LampStyle {
        let stored = attentionMotion[attention.rawValue] ?? WidgetTheme.attentionMotion[attention.rawValue]
        return LampStyle(
            color: accent(for: attention),
            motion: stored.flatMap { SessionLampAppearance.Motion(rawValue: $0.motion) } ?? .steady,
            gradientColor: stored.flatMap { NSColor(hex: $0.fadeTo) } ?? NSColor(sRGB: "#FFFFFF"),
            animationCycle: (stored?.cycle ?? WidgetTheme.markCycle).clamped(
                to: LampStyle.animationCycleRange, or: WidgetTheme.markCycle)
        )
    }

    mutating func setMarkMotion(
        _ motion: SessionLampAppearance.Motion, fadeTo: NSColor, cycle: Double, for attention: SessionAttention
    ) {
        attentionMotion[attention.rawValue] = WidgetTheme.Motion(
            motion: motion, fadeTo: fadeTo.srgbHex ?? "#FFFFFF",
            cycle: cycle.clamped(to: LampStyle.animationCycleRange, or: WidgetTheme.markCycle))
    }

    var menuColors: WidgetTheme.MenuColors {
        get { WidgetTheme.MenuColors(rawValue: menu.colors) ?? .state }
        set { menu.colors = newValue.rawValue }
    }

    var menuMotion: WidgetTheme.MenuMotion {
        get { WidgetTheme.MenuMotion(rawValue: menu.motion) ?? .none }
        set { menu.motion = newValue.rawValue }
    }

    /// A menu line's mark, for a session in this phase: the colour and the movement the
    /// theme's `menu` block chooses between the state's and the session's own lamp.
    func menuMarkStyle(for phase: SessionPhase) -> LampStyle {
        let lamp = lampScheme.style(for: phase)
        let state = markStyle(for: phase.attention)
        var style = state
        style.color = menuColors == .lamp ? lamp.color : state.color
        switch menuMotion {
        case .none:
            style.motion = .steady
        case .state:
            break
        case .lamp:
            style.motion = lamp.motion
            style.gradientColor = lamp.gradientColor
            style.animationCycle = lamp.animationCycle
        }
        return style
    }

    var widgetBackground: WidgetBackground {
        NSColor(hex: background).flatMap(WidgetBackground.init(custom:)) ?? .defaultBackground
    }

    mutating func setBackground(_ colour: NSColor) {
        background = colour.srgbHex ?? background
    }

    var widgetMaterial: WidgetMaterial {
        get { WidgetMaterial(rawValue: material) ?? .glass }
        set { material = newValue.rawValue }
    }

    var widgetOpacity: CGFloat {
        get { CGFloat(opacity.clamped(to: WidgetTheme.opacityRange, or: WidgetTheme.defaultOpacity)) }
        set { opacity = Double(newValue).clamped(to: WidgetTheme.opacityRange, or: WidgetTheme.defaultOpacity) }
    }

    var sphereMotion: WidgetTheme.Sphere {
        sphere.clamped
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
                animationCycle: lamp.cycle.clamped(to: LampStyle.animationCycleRange, or: fallback.animationCycle)
            )
        }
        return LampScheme(styles: styles)
    }

    mutating func setLampStyle(_ style: LampStyle, for phase: SessionPhase) {
        var clamped = style
        clamped.animationCycle = style.animationCycle.clamped(
            to: LampStyle.animationCycleRange, or: phase.defaultLampStyle.animationCycle)
        lamps[phase.rawValue] = WidgetTheme.Lamp(clamped)
    }
}

extension Double {
    /// Held inside `range`, and `fallback` for a number that is not one — a file may say
    /// anything.
    func clamped(to range: ClosedRange<Double>, or fallback: Double) -> Double {
        isFinite ? Swift.min(Swift.max(self, range.lowerBound), range.upperBound) : fallback
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
