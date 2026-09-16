import AgentWatchCore

/// The same state the icon shows, in words.
///
/// The icon is four numbers beside four marks, which is fast to read and impossible to read
/// aloud. This line is what the menu puts at the top, what the item's tooltip says, and what
/// a screen reader is given — one sentence, so the three cannot drift apart.
enum MenuBarSummaryText {
    /// Cells holding nothing are left out, unlike in the icon.
    ///
    /// A zero earns its place in the drawing: the four cells keep fixed positions only if
    /// none of them disappears, and a reader who has learnt where "working" sits should not
    /// have to find it again. In a sentence it earns nothing — "0 done" is a word about
    /// something that did not happen.
    static func line(for counts: SessionAttentionCounts) -> String {
        var parts: [String] = []
        if counts.needsPerson > 0 {
            parts.append(counts.needsPerson == 1 ? "1 needs you" : "\(counts.needsPerson) need you")
        }
        if counts.working > 0 {
            parts.append("\(counts.working) working")
        }
        if counts.done > 0 {
            parts.append("\(counts.done) done")
        }
        if counts.quiet > 0 {
            parts.append("\(counts.quiet) idle")
        }
        guard !parts.isEmpty else {
            // The words the widget uses when it has nothing to show. One application, one
            // way of saying that nothing is running.
            return "No active sessions"
        }
        return parts.joined(separator: " · ")
    }
}
