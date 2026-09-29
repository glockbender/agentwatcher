import AgentWatchCore
import AppKit

/// What the widget is drawn on: one of the colours the palette offers, or one of the person's own.
///
/// A value rather than an enum since the palette stopped being a closed list. Nothing switches
/// over it — every caller asks it for a colour — so a preset and a colour picked on the wheel
/// are the same kind of thing, and the only difference is where the colour came from.
struct WidgetBackground: Hashable {
    /// What the preferences file calls it: the preset's own name, or `custom`, whose colour is
    /// kept under a key of its own.
    let storedName: String
    let title: String
    let color: NSColor
    /// Whether the text on it is dark. Worked out from the colour, once, for every background
    /// alike — see `wantsDarkText(on:)`.
    private let isLight: Bool

    private init(storedName: String, title: String, color: NSColor) {
        self.storedName = storedName
        self.title = title
        self.color = color
        isLight = Self.wantsDarkText(on: color)
    }

    /// A colour of the person's own, at the precision the preferences file keeps it.
    ///
    /// Taken through `#RRGGBB` here rather than by the store alone, so the widget that is drawn
    /// while the wheel is being dragged is the widget the next launch draws. `nil` for what has
    /// no such spelling — a pattern from the panel's image page, say.
    init?(custom color: NSColor) {
        guard let hex = color.srgbHex, let stored = NSColor(hex: hex) else {
            return nil
        }
        self.init(storedName: Self.customName, title: "Custom", color: stored)
    }

    static let customName = "custom"
    static let defaultBackground = WidgetBackground(
        storedName: customName, title: "Custom", color: NSColor(sRGB: "#006996"))

    var isCustom: Bool {
        storedName == Self.customName
    }

    static let graphite = preset("graphite", NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1))
    static let midnight = preset("midnight", NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.22, alpha: 1))
    static let forest = preset("forest", NSColor(calibratedRed: 0.07, green: 0.17, blue: 0.14, alpha: 1))
    static let plum = preset("plum", NSColor(calibratedRed: 0.17, green: 0.10, blue: 0.22, alpha: 1))
    static let cocoa = preset("cocoa", NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.08, alpha: 1))
    static let slate = preset("slate", NSColor(calibratedRed: 0.11, green: 0.17, blue: 0.22, alpha: 1))
    static let pearl = preset("pearl", NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1))
    static let sand = preset("sand", NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.84, alpha: 1))
    static let mint = preset("mint", NSColor(calibratedRed: 0.88, green: 0.96, blue: 0.92, alpha: 1))
    static let sky = preset("sky", NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.99, alpha: 1))

    static func preset(named name: String) -> WidgetBackground? {
        [graphite, midnight, forest, plum, cocoa, slate, pearl, sand, mint, sky].first { $0.storedName == name }
    }

    /// A preset's title is its stored name, capitalised — written once so the two cannot drift.
    private static func preset(_ name: String, _ color: NSColor) -> WidgetBackground {
        WidgetBackground(storedName: name, title: name.capitalized, color: color)
    }

    var foregroundColor: NSColor {
        isLight ? Self.darkText : NSColor(calibratedWhite: 1, alpha: 1)
    }

    /// The appearance AppKit is to draw controls on this background in — the bezel of a row's
    /// `×`, which takes the system's own colours rather than these. Left to inherit the Mac's,
    /// a dark widget under the light appearance drew a near-black `×` on a dark bezel.
    var controlAppearance: NSAppearance? {
        NSAppearance(named: isLight ? .aqua : .darkAqua)
    }

    private static let darkText = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)

    /// Whether dark text stands out from this colour more than white does.
    ///
    /// Asked of the colour since a person can pick one: the palette's own ten were sorted into
    /// dark and light by hand, and a colour off the wheel has nobody to sort it. Judged by the
    /// contrast ratio WCAG defines, against the two text colours the widget actually has, rather
    /// than by a brightness cut-off chosen by eye. The cut-off that falls out of the arithmetic
    /// is a relative luminance of 0.224: `#828282` still takes white, `#838383` takes dark.
    private static func wantsDarkText(on color: NSColor) -> Bool {
        let background = relativeLuminance(of: color)
        let againstWhite = 1.05 / (background + 0.05)
        let againstDark = (background + 0.05) / (relativeLuminance(of: darkText) + 0.05)
        return againstDark > againstWhite
    }

    /// WCAG's relative luminance: the sRGB channels made linear, weighted the way the eye
    /// weighs them.
    private static func relativeLuminance(of color: NSColor) -> CGFloat {
        // Every colour here is a preset literal or a `#RRGGBB` one, and both convert. A literal
        // that did not would come out as black and take white text — which the agreement test
        // over the palette would see.
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return 0
        }
        let linear = { (channel: CGFloat) -> CGFloat in
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    /// The wash under a hovered row. Faint on purpose: it answers "which row am I on"
    /// without competing with the lamp for attention.
    var hoverColor: NSColor {
        foregroundColor.withAlphaComponent(isLight ? 0.08 : 0.12)
    }

    var secondaryForegroundColor: NSColor {
        isLight
            ? NSColor(calibratedRed: 0.29, green: 0.33, blue: 0.38, alpha: 1)
            : NSColor(calibratedWhite: 1, alpha: 0.68)
    }

    /// The marker for a session the app has stopped being sure about.
    ///
    /// Amber rather than red: nothing has failed in the session itself, and a red row would
    /// send a person looking at the agent instead of at the monitoring. Its shape is a
    /// triangle beside the lamp's disc, so the colour is not carrying the meaning alone —
    /// which matters here more than anywhere, because half the palette is light and
    /// `systemYellow` is invisible on sand.
    var warningColor: NSColor {
        isLight
            ? NSColor(calibratedRed: 0.70, green: 0.44, blue: 0.02, alpha: 1)
            : NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.29, alpha: 1)
    }
}

/// What the widget's panel is made of.
enum WidgetMaterial: String, CaseIterable {
    /// Liquid Glass carrying the chosen colour. The default where the system has it.
    case glass
    /// Liquid Glass that lets more of the desktop through, for a quiet wallpaper.
    case clearGlass
    /// The frosted material every macOS before 26 has.
    case frosted
    /// The chosen colour and nothing behind it, for a busy wallpaper.
    case solid

    var name: String {
        switch self {
        case .glass: "Glass"
        case .clearGlass: "Clear glass"
        case .frosted: "Frosted"
        case .solid: "Solid"
        }
    }

    var needsLiquidGlass: Bool {
        self == .glass || self == .clearGlass
    }

    /// The system, and the build: one made with an SDK older than macOS 26 draws no glass
    /// anywhere (`makeGlass`), and settings that offered it would promise what it cannot draw.
    static var systemHasLiquidGlass: Bool {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) { true } else { false }
        #else
            false
        #endif
    }

    /// What is drawn: glass asked for on a system without it is frosted.
    var drawn: WidgetMaterial {
        needsLiquidGlass && !Self.systemHasLiquidGlass ? .frosted : self
    }

    /// Kept here rather than handed down through every view that draws a backdrop; set from
    /// the theme in use, and the widget is rebuilt on every change.
    @MainActor static var current: WidgetMaterial = .glass
}

/// The widget's panel as versions before themes kept it, one setting per key — read once at
/// launch, to carry into a theme (`ThemeStore.adoptIfNeeded`).
///
/// The colour keys stay where they are, as the lamp's do: they only matter while no theme has
/// been chosen, and a theme is chosen by the first launch that reads them. Material and opacity
/// are forgotten once carried, because they can be carried into a theme already in use.
final class WidgetBackgroundStore {
    private enum Key {
        static let selectedBackground = "widgetBackground"
        /// The person's own colour, as `#RRGGBB`.
        static let customColor = "widgetBackgroundCustomColor"
        static let opacity = "widgetBackgroundOpacity"
        static let material = "widgetBackgroundMaterial"
    }

    private let preferences: PreferenceFile

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    /// The default blue for anything that cannot be read — a mistyped name, or `custom` with no colour
    /// behind it.
    var selected: WidgetBackground {
        let name = preferences.string(forKey: Key.selectedBackground) ?? ""
        if name == WidgetBackground.customName {
            return customColor.flatMap(WidgetBackground.init(custom:)) ?? .defaultBackground
        }
        return WidgetBackground.preset(named: name) ?? .defaultBackground
    }

    /// The saved custom colour; nil if absent or invalid.
    var customColor: NSColor? {
        preferences.string(forKey: Key.customColor).flatMap(NSColor.init(hex:))
    }

    /// The opacity a person set before it joined the theme, or nil when there is none to carry.
    var opacity: CGFloat? {
        preferences.number(forKey: Key.opacity).map {
            CGFloat($0.clamped(to: WidgetTheme.opacityRange, or: WidgetTheme.defaultOpacity))
        }
    }

    var material: WidgetMaterial? {
        preferences.string(forKey: Key.material).flatMap(WidgetMaterial.init(rawValue:))
    }

    /// Once carried into a theme, the two are the theme's, and a key left behind would be
    /// carried again over whatever the theme says by then.
    func forgetSurface() {
        preferences.removeValue(forKey: Key.opacity)
        preferences.removeValue(forKey: Key.material)
    }
}
