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
    /// The template this row is drawn from.
    ///
    /// Carried on the model rather than read at drawing time so that changing the template
    /// is a change to every row: two templates can produce the same name and the same
    /// dismissal — one with the branch and one without — and a model holding only those
    /// would compare equal, leaving the list with the rows it already had.
    let layout: RowLayout
    /// The name as this row will show it, or `nil` when the row shows none.
    let name: String?
    /// What the part that gives way says, measured and inserted after the rest of the row.
    ///
    /// The name while the name is that part, which is every row until somebody changes it —
    /// and something else entirely afterwards. Kept beside `name` rather than instead of it
    /// because both can be in one row: with the branch giving way, the name is still drawn,
    /// at its own full width.
    let flexibleText: String?
    /// Whether the row offers a `×`, and if it does but cannot work yet, from when it will.
    /// From the clock, by a threshold: a session left silent long enough gains a working
    /// button without an event of its own, which is why `now` is an input. The date inside
    /// `notYet` does not move between ticks, so a row does not rebuild for holding one.
    let dismissal: RowDismissal

    var id: String {
        snapshot.id
    }

    init(snapshot: SessionSnapshot, now: Date, layout: RowLayout) {
        self.snapshot = snapshot
        self.layout = layout
        name = rowName(for: snapshot, layout: layout)
        flexibleText = layout.flexible.flatMap { rowPartText($0, for: snapshot, layout: layout) }
        dismissal = SessionPresence.dismissal(of: snapshot, now: now)
    }
}
