import Foundation

/// What has to happen to the list of rows so that it shows a new set of models.
///
/// Stated over the models and applied afterwards, so the decision can be read and tested
/// without a window. For an ordinary event — one session said something — the answer is one
/// name in `rebuilt` and nothing else, which is the whole point: every other row, including
/// the one the pointer is resting on, is left exactly as it is.
struct RowListUpdate: Equatable {
    /// Sessions that left the list. Their rows go.
    var removed: [String] = []
    /// Sessions still here whose row now draws something different.
    var rebuilt: [String] = []
    /// Sessions that were not here before.
    var inserted: [String] = []
    /// Every session, in the order the rows must end up in.
    var order: [String] = []
    /// Whether the list on screen is already right. The commonest answer by far — a sweep
    /// that found nothing publishes the whole set again — and the one that keeps the row
    /// under the pointer alive.
    var changesNothing = true
}

/// Compares two sets of row models by session.
///
/// By session and not by position: a closed session sinks below the live ones
/// (`orderedForDisplay`), and a comparison by position would call that a change to every row
/// it moved past.
func rowListUpdate(from old: [HUDRowModel], to new: [HUDRowModel]) -> RowListUpdate {
    let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let newIDs = Set(new.map(\.id))

    var update = RowListUpdate()
    update.removed = old.map(\.id).filter { !newIDs.contains($0) }
    update.order = new.map(\.id)
    for model in new {
        guard let previous = oldByID[model.id] else {
            update.inserted.append(model.id)
            continue
        }
        if previous != model {
            update.rebuilt.append(model.id)
        }
    }
    update.changesNothing =
        update.removed.isEmpty && update.rebuilt.isEmpty && update.inserted.isEmpty
        && update.order == old.map(\.id)
    return update
}
