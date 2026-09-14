import AgentWatchCore
import Foundation

/// What one row draws, decided before any view exists.
///
/// It is what tells a rebuild from a redraw: two models that compare equal mean the row on
/// screen is already right and must not be touched, so an event about one session leaves
/// every other row — and whatever the pointer was resting on — alone.
///
/// Everything that depends on the clock is reduced here to the thresholds that are actually
/// visible. A row does not change because a second passed; it changes when the session
/// crosses into being dismissible. The elapsed time itself is deliberately absent: the row
/// restates that once a second on its own (`HUDSessionRowView.refreshTimer`), and a model
/// carrying it would compare unequal every tick and rebuild the whole list for a changed
/// digit.
struct HUDRowModel: Equatable {
    let snapshot: SessionSnapshot
    /// The name as this row will show it, or `nil` when the row shows none.
    let name: String?
    /// Whether the row offers a `×`, and if it does but cannot work yet, from when it will.
    /// From the clock, by a threshold: a session left silent long enough gains a working
    /// button without an event of its own, which is why `now` is an input. The date inside
    /// `notYet` does not move between ticks, so a row does not rebuild for holding one.
    let dismissal: RowDismissal

    var id: String {
        snapshot.id
    }

    init(snapshot: SessionSnapshot, now: Date, showsSessionTopic: Bool) {
        self.snapshot = snapshot
        name = rowName(for: snapshot, showsSessionTopic: showsSessionTopic)
        dismissal = SessionPresence.dismissal(of: snapshot, now: now)
    }
}
