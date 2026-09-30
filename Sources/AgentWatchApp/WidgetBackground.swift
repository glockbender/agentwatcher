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
        isLight ? Self.darkText : .white
    }

    /// The appearance AppKit is to draw controls on this background in — the bezel of a row's
    /// `×`, which takes the system's own colours rather than these. Left to inherit the Mac's,
    /// a dark widget under the light appearance drew a near-black `×` on a dark bezel.
    var controlAppearance: NSAppearance? {
        NSAppearance(named: isLight ? .aqua : .darkAqua)
    }

    private static var darkText: NSColor { WidgetTheme.active.color(.ink) }

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
        foregroundColor.withAlphaComponent(
            isLight ? WidgetTheme.motion.hoverWashLight : WidgetTheme.motion.hoverWashDark)
    }

    var secondaryForegroundColor: NSColor {
        WidgetTheme.active.color(isLight ? .inkSecondaryOnLight : .inkSecondaryOnDark)
    }

    /// The marker for a session the app has stopped being sure about.
    ///
    /// Amber rather than red: nothing has failed in the session itself, and a red row would
    /// send a person looking at the agent instead of at the monitoring. Its shape is a
    /// triangle beside the lamp's disc, so the colour is not carrying the meaning alone —
    /// which matters here more than anywhere, because half the palette is light and
    /// `systemYellow` is invisible on sand.
    var warningColor: NSColor {
        WidgetTheme.active.color(isLight ? .warningOnLight : .warningOnDark)
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

    static var systemHasLiquidGlass: Bool {
        if #available(macOS 26.0, *) { true } else { false }
    }

    /// What is drawn: glass asked for on a system without it is frosted.
    var drawn: WidgetMaterial {
        needsLiquidGlass && !Self.systemHasLiquidGlass ? .frosted : self
    }

    /// Kept here rather than handed down through every view that draws a backdrop; the store
    /// sets it, and the widget is rebuilt on every change.
    @MainActor static var current: WidgetMaterial = .glass
}

final class WidgetBackgroundStore: PreferenceDefaults {
    static let defaultOpacity: CGFloat = 0.82
    /// Not zero: an invisible widget cannot be found again by the person who made it
    /// invisible. At five percent it is already glass, and `Highlight Widget` can still
    /// point at it.
    static let minimumOpacity: CGFloat = 0.05

    private enum Key {
        static let selectedBackground = "widgetBackground"
        /// The person's own colour, as `#RRGGBB`. Its own key rather than folded into the one
        /// above, so it outlives a detour through a preset: the palette keeps offering it back.
        static let customColor = "widgetBackgroundCustomColor"
        static let opacity = "widgetBackgroundOpacity"
        static let material = "widgetBackgroundMaterial"
    }

    private let preferences: PreferenceFile

    var defaultValues: [String: JSONValue] {
        [
            Key.opacity: .number(Double(Self.defaultOpacity)),
            Key.material: .string(WidgetMaterial.glass.rawValue),
        ]
    }

    /// Told after every write, for the same reason `WidgetSettingsStore` is: nothing else
    /// tells the widget, and the follow-up belongs with the setting rather than with
    /// whichever control happened to make the write.
    var onChange: ((WidgetSetting) -> Void)?

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    /// The default blue for anything that cannot be read — a mistyped name, or `custom` with no colour
    /// behind it — for the reason the lamp store gives: the file is meant to be corrected by
    /// hand, and the app's own is the honest answer to "this is not a background".
    var selected: WidgetBackground {
        let name = preferences.string(forKey: Key.selectedBackground) ?? ""
        if name == WidgetBackground.customName {
            return customColor.flatMap(WidgetBackground.init(custom:)) ?? .defaultBackground
        }
        return WidgetBackground.preset(named: name) ?? .defaultBackground
    }

    /// The saved custom colour, seeded with default blue for new installations; nil if absent or invalid.
    var customColor: NSColor? {
        preferences.string(forKey: Key.customColor).flatMap(NSColor.init(hex:))
    }

    var opacity: CGFloat {
        guard let stored = preferences.number(forKey: Key.opacity) else {
            return Self.defaultOpacity
        }
        return normalizedOpacity(CGFloat(stored))
    }

    var material: WidgetMaterial {
        preferences.string(forKey: Key.material).flatMap(WidgetMaterial.init(rawValue:)) ?? .glass
    }

    func selectMaterial(_ material: WidgetMaterial) {
        preferences.set(material.rawValue, forKey: Key.material)
        onChange?(.background)
    }

    func selectOpacity(_ opacity: CGFloat) {
        preferences.set(Double(normalizedOpacity(opacity)), forKey: Key.opacity)
        onChange?(.backgroundOpacity)
    }

    private func normalizedOpacity(_ opacity: CGFloat) -> CGFloat {
        min(max(opacity, Self.minimumOpacity), 1)
    }
}
