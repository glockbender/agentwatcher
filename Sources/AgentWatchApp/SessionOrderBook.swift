import AgentWatchCore
import Foundation

/// The one order the widget and the menu both show, in the mode the settings name.
///
/// One object rather than an ordering each: an order that places a session by when it joined
/// its block has to remember that, and two memories would drift apart the first time one of
/// them looked while the other did not.
@MainActor
final class SessionOrderBook {
    private var ordering = SessionOrdering()
    private let settings: WidgetSettingsStore

    init(settings: WidgetSettingsStore) {
        self.settings = settings
    }

    func order(_ sessions: [SessionSnapshot], now: Date) -> [SessionSnapshot] {
        ordering.order(sessions, mode: settings.sessionOrder, blocks: settings.sessionBlockOrder, now: now)
    }
}
