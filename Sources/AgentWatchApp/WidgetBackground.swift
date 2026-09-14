import AgentWatchCore
import AppKit

enum WidgetBackground: String, CaseIterable, Hashable {
    case graphite
    case midnight
    case forest
    case plum
    case cocoa
    case slate
    case pearl
    case sand
    case mint
    case sky

    static let dark: [WidgetBackground] = [.graphite, .midnight, .forest, .plum, .cocoa, .slate]
    static let light: [WidgetBackground] = [.pearl, .sand, .mint, .sky]

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .forest: "Forest"
        case .plum: "Plum"
        case .cocoa: "Cocoa"
        case .slate: "Slate"
        case .pearl: "Pearl"
        case .sand: "Sand"
        case .mint: "Mint"
        case .sky: "Sky"
        }
    }

    var color: NSColor {
        switch self {
        case .graphite: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        case .midnight: NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.22, alpha: 1)
        case .forest: NSColor(calibratedRed: 0.07, green: 0.17, blue: 0.14, alpha: 1)
        case .plum: NSColor(calibratedRed: 0.17, green: 0.10, blue: 0.22, alpha: 1)
        case .cocoa: NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.08, alpha: 1)
        case .slate: NSColor(calibratedRed: 0.11, green: 0.17, blue: 0.22, alpha: 1)
        case .pearl: NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1)
        case .sand: NSColor(calibratedRed: 0.98, green: 0.93, blue: 0.84, alpha: 1)
        case .mint: NSColor(calibratedRed: 0.88, green: 0.96, blue: 0.92, alpha: 1)
        case .sky: NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.99, alpha: 1)
        }
    }

    var foregroundColor: NSColor {
        isLight
            ? NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
            : NSColor(calibratedWhite: 1, alpha: 1)
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

    private var isLight: Bool {
        Self.light.contains(self)
    }
}

final class WidgetBackgroundStore: PreferenceDefaults {
    static let defaultOpacity: CGFloat = 0.96
    /// Not zero: an invisible widget cannot be found again by the person who made it
    /// invisible. At five percent it is already glass, and `Highlight Widget` can still
    /// point at it.
    static let minimumOpacity: CGFloat = 0.05

    private enum Key {
        static let selectedBackground = "widgetBackground"
        static let opacity = "widgetBackgroundOpacity"
    }

    private let preferences: PreferenceFile

    var defaultValues: [String: JSONValue] {
        [
            Key.selectedBackground: .string(WidgetBackground.graphite.rawValue),
            Key.opacity: .number(Double(Self.defaultOpacity)),
        ]
    }

    /// Told after every write, for the same reason `WidgetSettingsStore` is: nothing else
    /// tells the widget, and the follow-up belongs with the setting rather than with
    /// whichever control happened to make the write.
    var onChange: ((WidgetSetting) -> Void)?

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    var selected: WidgetBackground {
        guard
            let rawValue = preferences.string(forKey: Key.selectedBackground),
            let background = WidgetBackground(rawValue: rawValue)
        else {
            return .graphite
        }
        return background
    }

    var opacity: CGFloat {
        guard let stored = preferences.number(forKey: Key.opacity) else {
            return Self.defaultOpacity
        }
        return normalizedOpacity(CGFloat(stored))
    }

    func select(_ background: WidgetBackground) {
        preferences.set(background.rawValue, forKey: Key.selectedBackground)
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
