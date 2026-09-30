import AgentWatchCore
import AppKit

/// Every colour and animation the widget, the menu bar and the menu are drawn with, for light
/// and for dark.
///
/// One file per theme in the `Themes` folder, so a theme can be shared, edited by hand, or
/// written by somebody else. Anything a file leaves out is taken from `standard`, in the same
/// mode; a value of the wrong kind makes the file unreadable, and the settings window says
/// which file and why (ADR-0017).
struct WidgetTheme: Codable, Equatable {
    var name: String
    var light: Look
    var dark: Look

    init(name: String, light: Look, dark: Look) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    /// A look is filled in from the built-in theme's look of the same mode.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(.name, or: "Untitled Theme")
        light =
            try values.contains(.light)
            ? Look(from: values.superDecoder(forKey: .light), defaults: Self.standard.light) : Self.standard.light
        dark =
            try values.contains(.dark)
            ? Look(from: values.superDecoder(forKey: .dark), defaults: Self.standard.dark) : Self.standard.dark
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
        /// A state that takes its colour from a lamp instead: state → phase, or
        /// `mostSessions` for the lamp of the phase most of its sessions are in at the moment.
        /// Only a phase of that state counts (`SessionPhase.attention`); anything else leaves
        /// the state its own colour.
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

        init(from decoder: Decoder) throws {
            try self.init(from: decoder, defaults: WidgetTheme.standard.dark)
        }

        /// What the file leaves out is `defaults`'s.
        init(from decoder: Decoder, defaults: Look) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            background = try values.decode(.background, or: defaults.background)
            material = try values.decode(.material, or: defaults.material)
            opacity = try values.decode(.opacity, or: defaults.opacity)
            lamps = try values.decode(.lamps, or: defaults.lamps)
            attention = try values.decode(.attention, or: defaults.attention)
            attentionLamps = try values.decode(.attentionLamps, or: defaults.attentionLamps)
            attentionMotion = try values.decode(.attentionMotion, or: defaults.attentionMotion)
            colors = try values.decode(.colors, or: defaults.colors)
            menu = try values.decode(.menu, or: defaults.menu)
            sphere = try values.decode(.sphere, or: defaults.sphere)
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
            motion = try values.decode(.motion, or: SessionLampAppearance.Motion.steady.rawValue)
            fadeTo = try values.decode(.fadeTo, or: "#FFFFFF")
            cycle = try values.decode(.cycle, or: WidgetTheme.markCycle)
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
            let standard = Menu()
            colors = try values.decode(.colors, or: standard.colors)
            motion = try values.decode(.motion, or: standard.motion)
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
            halo = try values.decode(.halo, or: standard.halo)
            haloBreathes = try values.decode(.haloBreathes, or: standard.haloBreathes)
            haloCycle = try values.decode(.haloCycle, or: standard.haloCycle)
            sway = try values.decode(.sway, or: standard.sway)
            swayDegrees = try values.decode(.swayDegrees, or: standard.swayDegrees)
            swayCycle = try values.decode(.swayCycle, or: standard.swayCycle)
            swell = try values.decode(.swell, or: standard.swell)
            swellSeconds = try values.decode(.swellSeconds, or: standard.swellSeconds)
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

    /// Where a state's colour comes from.
    enum ColourSource: Hashable {
        /// The state's own colour.
        case own
        /// Always this phase's lamp.
        case lamp(SessionPhase)
        /// The lamp of the phase most of the state's sessions are in at the moment.
        case mostSessions

        static let mostSessionsName = "mostSessions"
    }

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
    func accent(for attention: SessionAttention, phases: [SessionPhase: Int]) -> NSColor {
        if let phase = lamp(for: attention, phases: phases) {
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

    func colourSource(for attention: SessionAttention) -> WidgetTheme.ColourSource {
        let stored = attentionLamps[attention.rawValue]
        if stored == WidgetTheme.ColourSource.mostSessionsName, !attention.phases.isEmpty {
            return .mostSessions
        }
        guard let phase = stored.flatMap(SessionPhase.init(rawValue:)), phase.attention == attention else {
            return .own
        }
        return .lamp(phase)
    }

    mutating func setColourSource(_ source: WidgetTheme.ColourSource, for attention: SessionAttention) {
        switch source {
        case .own:
            attentionLamps[attention.rawValue] = nil
        case let .lamp(phase):
            attentionLamps[attention.rawValue] = phase.attention == attention ? phase.rawValue : nil
        case .mostSessions:
            attentionLamps[attention.rawValue] = WidgetTheme.ColourSource.mostSessionsName
        }
    }

    /// The phase whose lamp the state takes its colour from now, if it takes one at all.
    ///
    /// For `mostSessions`, the phase most of the state's sessions are in. A tie goes to the
    /// state's lead phase, then to the phases in their order, and a state with no sessions
    /// takes its lead phase — it shows nowhere then, but its colour in the editor has to be one.
    func lamp(for attention: SessionAttention, phases: [SessionPhase: Int]) -> SessionPhase? {
        switch colourSource(for: attention) {
        case .own:
            return nil
        case let .lamp(phase):
            return phase
        case .mostSessions:
            let lead = attention.leadPhase
            let ranked = attention.phases.sorted { phases[$0, default: 0] > phases[$1, default: 0] }
            guard let top = ranked.first else { return lead }
            let topCount = phases[top, default: 0]
            if let lead, phases[lead, default: 0] == topCount {
                return lead
            }
            return top
        }
    }

    mutating func setLamp(_ phase: SessionPhase?, for attention: SessionAttention) {
        setColourSource(phase.map { .lamp($0) } ?? .own, for: attention)
    }

    /// Whether every state shown in the menu bar takes a lamp's colour, and the menu's lines
    /// their own session's lamp: the one switch for a person who wants everything to match.
    var followsLamps: Bool {
        SessionAttention.counted.allSatisfy { colourSource(for: $0) != .own } && menuColors == .lamp
    }

    /// Turned on, every state that has its own colour takes the lamp most of its sessions are
    /// in; a lamp chosen by hand stays.
    mutating func setFollowsLamps(_ follows: Bool) {
        for attention in SessionAttention.counted {
            if !follows {
                setColourSource(.own, for: attention)
            } else if colourSource(for: attention) == .own {
                setColourSource(.mostSessions, for: attention)
            }
        }
        menuColors = follows ? .lamp : .state
    }

    /// Whether any state's colour depends on which phases its sessions are in.
    var dependsOnSessionPhases: Bool {
        SessionAttention.counted.contains { colourSource(for: $0) == .mostSessions }
    }

    /// Whether sessions moving from one set of phases to another change a colour this look
    /// draws, which is what the icon is redrawn for besides its counts.
    func isRedrawn(forPhases phases: [SessionPhase: Int], after previous: [SessionPhase: Int]) -> Bool {
        dependsOnSessionPhases && phases != previous
    }

    /// The state's mark as the grid and the menu draw it: its colour and how it moves.
    func markStyle(for attention: SessionAttention, phases: [SessionPhase: Int]) -> LampStyle {
        let stored = attentionMotion[attention.rawValue] ?? WidgetTheme.attentionMotion[attention.rawValue]
        return LampStyle(
            color: accent(for: attention, phases: phases),
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

    /// Changes one thing about the state's mark and keeps the rest as this look has it — which
    /// matters when a change goes into both looks and they differ.
    mutating func changeMarkStyle(for attention: SessionAttention, _ change: (inout LampStyle) -> Void) {
        // Without the sessions' phases: only the movement is written, never the colour.
        var style = markStyle(for: attention, phases: [:])
        change(&style)
        setMarkMotion(style.motion, fadeTo: style.gradientColor, cycle: style.animationCycle, for: attention)
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
    func menuMarkStyle(for phase: SessionPhase, phases: [SessionPhase: Int]) -> LampStyle {
        let lamp = lampScheme.style(for: phase)
        let state = markStyle(for: phase.attention, phases: phases)
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

    mutating func restoreDefaultLamps() {
        lamps = WidgetTheme.lamps(from: LampScheme())
    }

    /// Changes one thing about the phase's lamp and keeps the rest as this look has it.
    mutating func changeLampStyle(for phase: SessionPhase, _ change: (inout LampStyle) -> Void) {
        var style = lampScheme.style(for: phase)
        change(&style)
        setLampStyle(style, for: phase)
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

extension KeyedDecodingContainer {
    /// The value under `key`, or `fallback` when the file leaves it out. A value of the wrong
    /// kind still throws: a guess at what a mistyped field meant would be drawn as if chosen.
    fileprivate func decode<Value: Decodable>(_ key: Key, or fallback: Value) throws -> Value {
        try decodeIfPresent(Value.self, forKey: key) ?? fallback
    }
}
