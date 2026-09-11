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
    showsSessionTopic: Bool = true
) -> [HUDRowModel] {
    orderedForDisplay(sessions).map {
        HUDRowModel(snapshot: $0, now: now, showsSessionTopic: showsSessionTopic)
    }
}
