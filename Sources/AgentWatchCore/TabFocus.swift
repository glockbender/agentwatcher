import Foundation

/// What became of the second half of a focus press: asking somebody to select the tab.
///
/// The first half — raising the host — Agent Watch does itself and knows the result of. The
/// second half is always somebody else's work, so the most that can be honestly reported is
/// whether the request went out.
public enum TabFocusAttempt: Equatable, Sendable {
    /// Somebody was asked. Whether they found the tab is not knowable from here: neither the
    /// JetBrains daemon nor an Apple event reports back what the far side did.
    case asked

    /// This host has no way to address a tab at all — a terminal with no dictionary, a
    /// desktop client with no tabs. The ordinary case, and not news.
    case unaddressable

    /// Something a person could act on is missing, said in words for the log.
    case missing(String)

    /// The tab is gone and its host kept the terminal, so the agent runs on behind nothing a
    /// click could bring forward. The words are the evidence, for the log; what changes is
    /// the row, which the click marks as a closed terminal (ADR-0013).
    case gone(String)
}
