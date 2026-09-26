import AgentWatchCore
import AppKit

/// How each attention state is shown, written once.
///
/// The four states used to be spelled out by each surface that showed them — the icon's cells,
/// the summary line — each with its own order and its own words, and nothing checked that
/// they agreed. Everything now walks `SessionAttention.counted` and asks here.
///
/// No `default` in any switch: a state added to `SessionAttention` does not compile until it
/// has a mark and words, and then every surface shows it.
extension SessionAttention {
    var symbolName: String {
        switch self {
        case .needsPerson: "exclamationmark.circle.fill"
        case .working: "play.circle.fill"
        case .done: "checkmark.circle.fill"
        case .quiet: "minus.circle.fill"
        // Shown nowhere today, since nothing lists a closed session (ADR-0002). A real mark
        // rather than an optional, so that no caller has to unwrap a case it never meets.
        case .closed: "xmark.circle.fill"
        }
    }

    /// The accent drawn behind the mark. ADR-0012 says why these are fixed values.
    var accent: NSColor {
        switch self {
        case .needsPerson: MenuBarIconPalette.needsPerson
        case .working: MenuBarIconPalette.working
        case .done: MenuBarIconPalette.done
        case .quiet, .closed: MenuBarIconPalette.quiet
        }
    }

    /// How many sessions are in this state, as the summary line says it.
    func summaryPhrase(count: Int) -> String {
        switch self {
        case .needsPerson: count == 1 ? "1 needs you" : "\(count) need you"
        case .working: "\(count) working"
        case .done: "\(count) done"
        // `quiet` in the code, "idle" to a person: the lamp's name for the phase most of
        // these sessions are in.
        case .quiet: "\(count) idle"
        case .closed: "\(count) closed"
        }
    }
}
