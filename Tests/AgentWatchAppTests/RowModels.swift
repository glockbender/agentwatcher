import AgentWatchCore
import Foundation

@testable import AgentWatchApp

/// Sessions as the list now takes them: ordered for display, then reduced to what each row
/// draws. The same two steps the widget performs, so a test that builds a list by hand is
/// building the one the app would.
@MainActor
func rowModels(
    _ sessions: [SessionSnapshot],
    now: Date,
    layout: RowLayout = .standard
) -> [HUDRowModel] {
    orderedForDisplay(sessions).map {
        HUDRowModel(snapshot: $0, now: now, layout: layout)
    }
}

/// The template a person gets by taking the name out. The one case worth its own name here:
/// it is what the row and the hover card have to agree about — neither names a session the
/// other has stopped naming.
let layoutWithoutTheName = RowLayout(parts: RowLayout.standard.parts.filter { $0 != .name })
