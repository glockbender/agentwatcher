import AgentWatchCore
import AppKit

/// What the widget's text and controls are drawn for: a colour, and whether text on it is dark.
struct WidgetBackground: Hashable {
    let color: NSColor
    /// Whether the text on it is dark. Worked out from the colour, once, for every background
    /// alike — see `wantsDarkText(on:)`.
    private let isLight: Bool

    private init(color: NSColor) {
        self.color = color
        isLight = Self.wantsDarkText(on: color)
    }

    /// A theme's colour, at the precision a theme file keeps it.
    ///
    /// Taken through `#RRGGBB` here, so the widget that is drawn while the wheel is being dragged
    /// is the widget the next launch draws. `nil` for what has no such spelling — a pattern from
    /// the panel's image page, say.
    init?(custom color: NSColor) {
        guard let hex = color.srgbHex, let stored = NSColor(hex: hex) else {
            return nil
        }
        self.init(color: stored)
    }

    static let defaultBackground = WidgetBackground(color: NSColor(sRGB: "#006996"))

    /// The two neutral backgrounds: what the text on glass is drawn for in dark and in light
    /// mode (`WidgetMaterial.textBackground`).
    static let graphite = WidgetBackground(color: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1))
    static let pearl = WidgetBackground(color: NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1))

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
    /// Judged by the contrast ratio WCAG defines, against the two text colours the widget
    /// actually has, rather than by a brightness cut-off chosen by eye. The cut-off that falls
    /// out of the arithmetic is a relative luminance of 0.224: `#828282` still takes white,
    /// `#838383` takes dark.
    private static func wantsDarkText(on color: NSColor) -> Bool {
        let background = relativeLuminance(of: color)
        let againstWhite = 1.05 / (background + 0.05)
        let againstDark = (background + 0.05) / (relativeLuminance(of: darkText) + 0.05)
        return againstDark > againstWhite
    }

    /// WCAG's relative luminance: the sRGB channels made linear, weighted the way the eye
    /// weighs them.
    private static func relativeLuminance(of color: NSColor) -> CGFloat {
        // Every colour here is a literal or a `#RRGGBB` one, and both convert.
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
    /// which matters here more than anywhere, because `systemYellow` is invisible on a light
    /// background.
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

    /// What the widget's text is drawn for on this material. On glass the desktop, not the
    /// theme's colour, is behind the text, so the text follows light and dark mode as the Dock's
    /// labels do.
    func textBackground(for themeBackground: WidgetBackground, dark: Bool) -> WidgetBackground {
        guard needsLiquidGlass else {
            return themeBackground
        }
        return dark ? .graphite : .pearl
    }
}
