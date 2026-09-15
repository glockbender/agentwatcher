import AgentWatchCore
import AppKit

enum HUDPlacement {
    static func origin(
        savedOrigin: NSPoint?,
        size: NSSize,
        visibleFrames: [NSRect],
        primaryVisibleFrame: NSRect,
        margin: CGFloat
    ) -> NSPoint {
        guard
            let savedOrigin,
            let savedScreen = visibleFrames.first(where: { $0.contains(savedOrigin) })
        else {
            return upperRightOrigin(for: size, in: primaryVisibleFrame, margin: margin)
        }

        return clamped(savedOrigin, for: size, in: savedScreen, margin: margin)
    }

    /// The middle of a screen, where a widget that has been lost is easiest to find again.
    ///
    /// Deliberately not the upper-right corner a first launch uses. That corner is about
    /// staying out of the way of whatever is on screen; a reset is about the opposite — being
    /// impossible to miss — so the two answers differ on purpose.
    ///
    /// A widget larger than the screen it is centred on would hang off both edges at once.
    /// It is pinned to the near edge instead, so at least its leading corner is reachable.
    static func centeredOrigin(for size: NSSize, in visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: max(visibleFrame.minX, visibleFrame.midX - size.width / 2),
            y: max(visibleFrame.minY, visibleFrame.midY - size.height / 2)
        )
    }

    private static func upperRightOrigin(for size: NSSize, in frame: NSRect, margin: CGFloat) -> NSPoint {
        NSPoint(
            x: frame.maxX - size.width - margin,
            y: frame.maxY - size.height - margin
        )
    }

    private static func clamped(_ origin: NSPoint, for size: NSSize, in frame: NSRect, margin: CGFloat) -> NSPoint {
        let minimumX = frame.minX + margin
        let maximumX = max(minimumX, frame.maxX - size.width - margin)
        let minimumY = frame.minY + margin
        let maximumY = max(minimumY, frame.maxY - size.height - margin)
        return NSPoint(
            x: min(max(origin.x, minimumX), maximumX),
            y: min(max(origin.y, minimumY), maximumY)
        )
    }
}

/// Remembers where and how large the widget was left, and whether the size is its own choice.
///
/// Following the session count is a setting with a value, not a missing size. It was the
/// absence of a size once, which read well in the code and badly in the settings file: the
/// file is meant to describe the widget completely, and "no size" is a state only the source
/// could explain. With a value, a person reading the file sees both the size and whether it
/// is in force.
final class HUDFrameStore: PreferenceDefaults {
    /// Low enough that a single-session widget is not padded out to fill it, and no lower
    /// than the empty state: the widget sizes itself to this height when it has nothing to
    /// show, so a smaller minimum would let a drag clip the one thing left on screen.
    ///
    /// The tuned size's floor, and the one a fresh file is written with. What the widget is
    /// actually held to follows the scale — see `minimumSize` below.
    static let minimumSize = NSSize(width: 200, height: 56)
    /// What a widget that has never been resized is. Wide enough for a session name, and as
    /// short as the widget is allowed to be, because the height is about to be recomputed
    /// from the number of sessions anyway.
    static let defaultSize = NSSize(width: 340, height: minimumSize.height)

    private enum Key {
        static let originX = "widgetOriginX"
        static let originY = "widgetOriginY"
        static let width = "widgetWidth"
        static let height = "widgetHeight"
        static let sizeFollowsSessions = "widgetSizeFollowsSessions"
    }

    private let preferences: PreferenceFile

    /// The floor in force, which the scale moves: the empty state needs less room at half
    /// size and more at double, and `WidgetStyle.minimumWindowSize` is where that is decided.
    ///
    /// Kept here as well as on the window because both clamp, and they have to agree. While
    /// the scale only went up they always did — the window's floor was never below this one,
    /// so this clamp never bit. Going down it would have: a widget dragged to 150 points at
    /// half size is legal for the window and was rounded up to 200 on the way into the file,
    /// so it sprang back to a size nobody chose on the next launch.
    var minimumSize = HUDFrameStore.minimumSize

    /// The size and whether it is in force. The origin is not here: where the widget goes
    /// depends on the screen, so there is no answer to write until it has actually been put
    /// somewhere — the controller writes it at the first placement.
    var defaultValues: [String: JSONValue] {
        [
            Key.width: .number(Double(Self.defaultSize.width)),
            Key.height: .number(Double(Self.defaultSize.height)),
            // Read rather than asserted, so the value written on an upgrade is the one the
            // previous version's file already meant. See `sizeFollowsSessions`.
            Key.sizeFollowsSessions: .bool(sizeFollowsSessions),
        ]
    }

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    var savedOrigin: NSPoint? {
        guard
            let x = preferences.number(forKey: Key.originX),
            let y = preferences.number(forKey: Key.originY)
        else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    var size: NSSize {
        guard
            let width = preferences.number(forKey: Key.width),
            let height = preferences.number(forKey: Key.height)
        else {
            return Self.defaultSize
        }
        return clamped(NSSize(width: width, height: height))
    }

    /// Whether the height follows the number of sessions. Off the moment a size is chosen by
    /// hand, because a new session must not resize a window someone has just placed.
    ///
    /// A file with no such key was written before this setting existed, and back then the
    /// rule *was* the shape of the file: a size in it meant the widget had been resized and
    /// the chosen size won for good. So the absent key is read the way that version would
    /// have read it, rather than as the default a fresh install gets — otherwise the launch
    /// that adds the key hands every hand-sized widget back to the session count while the
    /// file goes on naming a size nothing will ever apply again.
    var sizeFollowsSessions: Bool {
        preferences.flag(forKey: Key.sizeFollowsSessions) ?? !hasStoredSize
    }

    /// Whether the file itself carries a size, which is the question the rule above turns on.
    private var hasStoredSize: Bool {
        preferences.number(forKey: Key.width) != nil && preferences.number(forKey: Key.height) != nil
    }

    func save(_ origin: NSPoint) {
        preferences.set(Double(origin.x), forKey: Key.originX)
        preferences.set(Double(origin.y), forKey: Key.originY)
    }

    /// A size chosen by hand, which is also what ends the following. The two go together
    /// here rather than at the call site: they are one rule, and a caller that saved a size
    /// without ending the following would have the next refresh undo the drag.
    func save(_ size: NSSize) {
        let clamped = clamped(size)
        preferences.set(Double(clamped.width), forKey: Key.width)
        preferences.set(Double(clamped.height), forKey: Key.height)
        preferences.set(false, forKey: Key.sizeFollowsSessions)
    }

    /// Returns the widget to sizing itself from the session count, and the size to the one a
    /// fresh install has. Writes both, like every other reset: the file keeps saying what the
    /// widget is rather than going quiet about it.
    func resetSize() {
        preferences.set(Double(Self.defaultSize.width), forKey: Key.width)
        preferences.set(Double(Self.defaultSize.height), forKey: Key.height)
        preferences.set(true, forKey: Key.sizeFollowsSessions)
    }

    func clamped(_ size: NSSize) -> NSSize {
        NSSize(
            width: max(size.width, minimumSize.width),
            height: max(size.height, minimumSize.height)
        )
    }
}
