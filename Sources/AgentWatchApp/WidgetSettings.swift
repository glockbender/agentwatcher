import AgentWatchCore
import Foundation

/// What happens to a session once the app knows it is over.
enum ClosedSessionRetention: Equatable {
    /// Keep it until the person dismisses it with `×`.
    case manual
    case after(TimeInterval)

    var seconds: TimeInterval {
        switch self {
        case .manual: 0
        case let .after(seconds): seconds
        }
    }

    init(seconds: TimeInterval) {
        self = seconds > 0 ? .after(seconds) : .manual
    }
}

/// Which setting changed, for the one place that knows what to do about it.
///
/// One vocabulary across both preference stores, so `AppDelegate` has one function that
/// knows the follow-up for every setting rather than one per store.
enum WidgetSetting {
    case interactionLocks
    case closedSessionRetention
    case transcriptPollInterval
    case background
    case backgroundOpacity
    case lampScheme
    case scale
    case toggleShortcut
    case rowLayout
    case menuBarCounts
}

/// Widget preferences that are not about colour.
///
/// The locks exist because the widget sits under the cursor all day: one stray drag
/// on the background moves it, and once it is resizable one stray drag on an edge
/// reshapes it. Locking is the only way to make those gestures impossible.
final class WidgetSettingsStore: PreferenceDefaults {
    static let defaultClosedSessionRetention: TimeInterval = 120
    static let offeredClosedSessionRetentions: [ClosedSessionRetention] = [
        .after(120),
        .after(600),
        .manual,
    ]

    /// Five seconds. The gap between a call ending and the row saying so, for the endings
    /// only the transcript reports — chosen because it is the slowest that still reads as
    /// the widget keeping up, and every tick costs a scan of a growing file.
    static let defaultTranscriptPollInterval: TimeInterval = 5
    /// `nil` is off. Offered rather than free-form because the honest range is narrow: below
    /// three seconds the reading costs more than the delay it saves, above ten the widget
    /// stops feeling live.
    static let offeredTranscriptPollIntervals: [TimeInterval?] = [3, 5, 10, nil]

    /// How much larger or smaller than its tuned size the widget may be drawn.
    ///
    /// Both ways round 1, in equal steps. The range started at 1 and went up, on the
    /// reasoning that every number in `WidgetStyle` was chosen at 1 and drawing below it only
    /// makes the widget worse; the owner asked for the other half, and a widget that is
    /// glanced at rather than read is a fair thing to want smaller. So the tuned size is the
    /// middle of the range now, not its floor.
    static let minimumScale: CGFloat = 0.5
    static let maximumScale: CGFloat = 2
    /// What a widget nobody has touched is drawn at. Its own constant, not the floor: while
    /// the range only went up, the two were the same number, and turning the range downwards
    /// silently made a fresh install open at half size.
    static let defaultScale: CGFloat = 1
    /// How far apart the stops the slider snaps to are, in percent.
    ///
    /// The range was offered in quarter steps first, which moves a quarter of the widget in
    /// one step: the owner asked for something finer, five percent at the coarsest. Still
    /// stops rather than a free slider — a slider with hundreds of positions offers sizes
    /// nobody can tell apart — but close enough together that a person settles on a size
    /// instead of choosing between the two either side of the one they wanted.
    static let scaleStepPercent = 5
    /// Every size on offer, the floor to the ceiling in `scaleStepPercent` steps.
    ///
    /// Counted in whole percents rather than by adding 0.05 repeatedly, because 0.05 is not a
    /// number a `Double` holds exactly and the last stop has to be `maximumScale` itself: it
    /// is where the slider ends, and a stop a hair short of it would be a size the widget can
    /// be set to and the list does not name.
    ///
    /// The quarter steps carried a second argument — that a quarter of a tuned number is
    /// still a whole point. It was never load-bearing: `WidgetStyle.points` rounds every
    /// scaled number anyway, which is what actually keeps a label off a half point.
    static let offeredScales: [CGFloat] = stride(
        from: Int((minimumScale * 100).rounded()),
        through: Int((maximumScale * 100).rounded()),
        by: scaleStepPercent
    ).map { CGFloat($0) / 100 }

    /// What a fresh install hides and shows the widget with — `⌥⌘W`.
    ///
    /// Kept as the text that goes into the file rather than built from a key code, because
    /// building one is failable: a default that might be nothing would need a fallback no test
    /// could ever reach. That these four characters really mean `⌥⌘W` is a test's job instead.
    static let defaultToggleShortcut = "opt+cmd+13"
    /// What the file holds when a person has cleared the shortcut.
    ///
    /// A state of its own rather than a missing key, because a missing key is what a fresh
    /// install looks like — and that one is given `⌥⌘W`.
    static let noToggleShortcut = ""

    private enum Key {
        static let locksPosition = "lockWidgetPosition"
        static let locksSize = "lockWidgetSize"
        static let closedSessionRetention = "closedSessionRetentionSeconds"
        static let transcriptPollInterval = "transcriptPollIntervalSeconds"
        static let scale = "widgetScale"
        static let toggleShortcut = "toggleWidgetShortcut"
        static let showsMenuBarCounts = "showsMenuBarCounts"
    }

    private let preferences: PreferenceFile

    var defaultValues: [String: JSONValue] {
        [
            Key.locksPosition: .bool(false),
            Key.locksSize: .bool(false),
            Key.closedSessionRetention: .number(Self.defaultClosedSessionRetention),
            Key.transcriptPollInterval: .number(Self.defaultTranscriptPollInterval),
            Key.scale: .number(Double(Self.defaultScale)),
            Key.toggleShortcut: .string(Self.defaultToggleShortcut),
            Key.showsMenuBarCounts: .bool(true),
        ]
    }

    /// Told after every write, so the follow-up for each setting is written once.
    ///
    /// Three collaborators read this store lazily and nothing tells them a value has moved,
    /// so every setting needs a poke afterwards — and each needs a different one. Those pokes used to live in the menu actions that made the write, which meant the
    /// full list of who has to be told was knowledge every writer had to carry. A forgotten
    /// one produces a setting that appears not to work and then fixes itself minutes later.
    var onChange: ((WidgetSetting) -> Void)?

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    var locksPosition: Bool {
        preferences.flag(forKey: Key.locksPosition) ?? false
    }

    var locksSize: Bool {
        preferences.flag(forKey: Key.locksSize) ?? false
    }

    var closedSessionRetention: ClosedSessionRetention {
        guard let stored = preferences.number(forKey: Key.closedSessionRetention) else {
            return .after(Self.defaultClosedSessionRetention)
        }
        return ClosedSessionRetention(seconds: stored)
    }

    /// How often each working session's transcript is read, or `nil` when it is not read.
    ///
    /// Turning it off leaves the hooks running: the widget keeps working and loses only the
    /// endings hooks never report — a call stopped by a person, and the real end of a
    /// background command.
    var transcriptPollInterval: TimeInterval? {
        guard let stored = preferences.number(forKey: Key.transcriptPollInterval) else {
            return Self.defaultTranscriptPollInterval
        }
        // A stored value out of range is treated as off rather than clamped: the only way one
        // gets there is an edited preferences file, and quietly reading a file every tenth of
        // a second because a number was mistyped is worse than not reading it.
        return (1...60).contains(stored) ? stored : nil
    }

    /// How much larger than its tuned size the widget draws itself.
    ///
    /// Clamped and snapped to a stop rather than refused, unlike the poll interval: a scale
    /// out of range is a number that still means something — larger, or smaller — where a
    /// mistyped interval is a file read at a rate nobody chose.
    var scale: CGFloat {
        guard let stored = preferences.number(forKey: Key.scale) else {
            return Self.defaultScale
        }
        return normalizedScale(CGFloat(stored))
    }

    /// Writes nothing when the value has not moved, which no other setter here has to care
    /// about: this one is behind a slider that fires on every frame of a drag, and each write
    /// rebuilds every row in the widget.
    func setScale(_ scale: CGFloat) {
        let normalized = normalizedScale(scale)
        guard normalized != self.scale else {
            return
        }
        preferences.set(Double(normalized), forKey: Key.scale)
        onChange?(.scale)
    }

    /// The nearest size on offer, so nothing but a stop is ever stored.
    ///
    /// The snapping lives here and not only in the slider, because the slider is not the only
    /// writer: an edited preferences file is one too, and a stored 1.07 would draw a widget at
    /// a size the window then reports as 105%.
    ///
    /// Counted in percent — `scale * 100 / 5`, not `scale / 0.05` — so the arithmetic stays on
    /// numbers a `Double` holds: normalizing a normalized value has to give the same value
    /// back, or `setScale` would write on every frame of a drag that changes nothing.
    private func normalizedScale(_ scale: CGFloat) -> CGFloat {
        let clamped = min(max(scale, Self.minimumScale), Self.maximumScale)
        let step = CGFloat(Self.scaleStepPercent)
        return (clamped * 100 / step).rounded() * step / 100
    }

    /// The combination that hides and shows the widget from anywhere, or nothing.
    var toggleShortcut: WidgetShortcut? {
        WidgetShortcut(
            stored: preferences.string(forKey: Key.toggleShortcut) ?? Self.defaultToggleShortcut
        )
    }

    /// Whether the status item shows the four counts rather than the plain app glyph.
    ///
    /// On unless it has been turned off, and that includes a copy updating into this version:
    /// the key is missing there too. So the item grows from 22 pt to around 51 pt without
    /// anybody asking for it — deliberate, because a feature that exists to be seen is not
    /// served by a switch almost nobody would find, and one menu item turns it off.
    var showsMenuBarCounts: Bool {
        preferences.flag(forKey: Key.showsMenuBarCounts) ?? true
    }

    func setShowsMenuBarCounts(_ isShown: Bool) {
        preferences.set(isShown, forKey: Key.showsMenuBarCounts)
        onChange?(.menuBarCounts)
    }

    func setToggleShortcut(_ shortcut: WidgetShortcut?) {
        preferences.set(shortcut?.stored ?? Self.noToggleShortcut, forKey: Key.toggleShortcut)
        onChange?(.toggleShortcut)
    }

    func setTranscriptPollInterval(_ interval: TimeInterval?) {
        preferences.set(interval ?? 0, forKey: Key.transcriptPollInterval)
        onChange?(.transcriptPollInterval)
    }

    func setLocksPosition(_ isLocked: Bool) {
        preferences.set(isLocked, forKey: Key.locksPosition)
        onChange?(.interactionLocks)
    }

    func setLocksSize(_ isLocked: Bool) {
        preferences.set(isLocked, forKey: Key.locksSize)
        onChange?(.interactionLocks)
    }

    func setClosedSessionRetention(_ retention: ClosedSessionRetention) {
        preferences.set(retention.seconds, forKey: Key.closedSessionRetention)
        onChange?(.closedSessionRetention)
    }
}
