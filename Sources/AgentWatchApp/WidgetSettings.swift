import AgentWatchCore
import AppKit

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
    case sessionTopic
    case closedSessionRetention
    case transcriptPollInterval
    case background
    case backgroundOpacity
    case lampScheme
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

    private enum Key {
        static let locksPosition = "lockWidgetPosition"
        static let locksSize = "lockWidgetSize"
        static let closedSessionRetention = "closedSessionRetentionSeconds"
        static let showsSessionTopic = "showsSessionTopic"
        static let transcriptPollInterval = "transcriptPollIntervalSeconds"
    }

    private let preferences: PreferenceFile

    var defaultValues: [String: JSONValue] {
        [
            Key.locksPosition: .bool(false),
            Key.locksSize: .bool(false),
            Key.closedSessionRetention: .number(Self.defaultClosedSessionRetention),
            Key.showsSessionTopic: .bool(true),
            Key.transcriptPollInterval: .number(Self.defaultTranscriptPollInterval),
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

    /// Only hides the topic. The sender resolves it either way, so promising more here
    /// than "stop showing it" would be a lie the app cannot keep.
    var showsSessionTopic: Bool {
        preferences.flag(forKey: Key.showsSessionTopic) ?? true
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

    func setShowsSessionTopic(_ isShown: Bool) {
        preferences.set(isShown, forKey: Key.showsSessionTopic)
        onChange?(.sessionTopic)
    }
}
