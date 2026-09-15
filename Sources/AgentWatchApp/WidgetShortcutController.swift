import AppKit

/// Keeps the system's table of shortcuts agreeing with the setting, and knows what to say when
/// it cannot.
///
/// Separate from the registrar so that *when* to register can be tested without registering,
/// and separate from `AppDelegate` so that the rule about taking the old combination down
/// before putting the new one up has somewhere to live and something to check it.
@MainActor
final class WidgetShortcutController {
    /// What the widget's shortcut is doing, in the words the settings window shows.
    enum Status: Equatable {
        /// Nobody has set one, or it was cleared.
        case none
        case active(WidgetShortcut)
        /// Registered twice over without being taken down in between — this application's own
        /// fault, never another application's. See `ShortcutRegistrationOutcome.alreadyOurs`.
        case alreadyOurs(WidgetShortcut)
        case refused(WidgetShortcut, code: Int32)
    }

    private(set) var status: Status = .none {
        didSet {
            guard status != oldValue else {
                return
            }
            onStatusChange?()
        }
    }

    /// So that the settings window and the status menu can show what happened without asking
    /// again on a timer.
    var onStatusChange: (() -> Void)?

    /// Goes quiet without giving the combination up.
    ///
    /// One caller, and one reason: while a new combination is being recorded the old one is
    /// still registered, and pressing it would hide the widget out from under the person
    /// choosing — with the very press they were trying to record.
    ///
    /// There was a second reason expected, and measurement took it away: an open status menu
    /// does **not** fire both the menu line and the shortcut. ADR-0009 holds the three runs.
    var isMuted = false

    private let settings: WidgetSettingsStore
    private let registrar: GlobalShortcutRegistering
    private let onToggle: () -> Void
    /// What is actually in the system's table right now, which is not the same as what the
    /// setting says: a combination the machine refused stays in the setting and never reaches
    /// the table.
    private var registered: WidgetShortcut?

    init(
        settings: WidgetSettingsStore,
        registrar: GlobalShortcutRegistering,
        onToggle: @escaping () -> Void
    ) {
        self.settings = settings
        self.registrar = registrar
        self.onToggle = onToggle
        registrar.onPress = { [weak self] in
            guard let self, !isMuted else {
                return
            }
            onToggle()
        }
    }

    /// Prints the combination beside a menu line — but only while pressing it would really do
    /// something.
    ///
    /// A menu that offers `⌥⌘W` while another application holds `⌥⌘W` promises what this app
    /// cannot deliver, and the person has no way to find that out from the menu. Saying why is
    /// the settings window's job; the menu's job is to stop claiming it.
    func showShortcut(on item: NSMenuItem) {
        guard case let .active(shortcut) = status else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = shortcut.menuKeyEquivalent
        item.keyEquivalentModifierMask = shortcut.menuModifierMask
    }

    /// Makes the table match the setting. Safe to call at launch and after every change.
    func apply() {
        if registered != nil {
            // Before, never after. The table is system-wide and counts this application's own
            // entry, so registering the new combination first collides with the old one as soon
            // as the two differ only by a modifier — and the machine reports that collision the
            // same way it reports somebody else's.
            registrar.unregister()
            registered = nil
        }
        guard let shortcut = settings.toggleShortcut else {
            status = .none
            return
        }
        switch registrar.register(shortcut) {
        case .registered:
            registered = shortcut
            status = .active(shortcut)
        case .alreadyOurs:
            status = .alreadyOurs(shortcut)
        case let .refused(code):
            status = .refused(shortcut, code: code)
        }
    }
}
