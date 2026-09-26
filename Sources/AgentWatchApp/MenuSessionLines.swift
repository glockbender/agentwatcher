import AgentWatchCore

/// One session as the status menu lists it.
struct MenuSessionLine: Equatable {
    /// What the click looks up at the moment it is made. The snapshot itself is not kept: a
    /// click is answered from the session as it is then, the rule the widget's rows follow.
    let sessionID: String
    let attention: SessionAttention
    let title: String
    /// `false` only when a click could do nothing at all — and the title then says why.
    let isEnabled: Bool
}

/// The sessions the menu lists, in the widget's order, and what each line says.
///
/// The widget's order rather than one of the menu's own: a person who knows where a row sits
/// in the widget finds its line in the same place. A closed session is never listed, whatever
/// the setting names (ADR-0002).
///
/// `reach` is asked only about a session whose terminal was closed. It is the one session
/// whose line reads differently for the answer, and asking walks the process tree — once per
/// line, every time the menu opens, would be a cost with nothing to show for it.
func menuSessionLines(
    for sessions: [SessionSnapshot],
    listing attentions: Set<SessionAttention>,
    reach: (SessionSnapshot) -> SessionReach
) -> [MenuSessionLine] {
    orderedForDisplay(sessions).compactMap { snapshot in
        let attention = snapshot.phase.attention
        guard SessionAttention.counted.contains(attention), attentions.contains(attention) else {
            return nil
        }
        let name = menuSessionName(for: snapshot)
        guard snapshot.phase == .terminalClosed else {
            return MenuSessionLine(sessionID: snapshot.id, attention: attention, title: name, isEnabled: true)
        }
        // The one click in the app that ends something. The widget's card says so before it
        // is made; a menu line has no card, so the line says it itself.
        guard case .closedTerminal(devicePath: .some) = reach(snapshot) else {
            return MenuSessionLine(
                sessionID: snapshot.id,
                attention: attention,
                title: "\(name) — terminal closed, nothing here can end it",
                isEnabled: false
            )
        }
        return MenuSessionLine(
            sessionID: snapshot.id,
            attention: attention,
            title: "\(name) — terminal closed, click ends the agent",
            isEnabled: true
        )
    }
}

/// The name a row shows with the app's own row layout, and never nothing: a line in a menu
/// with no words in it cannot be told from a gap.
private func menuSessionName(for snapshot: SessionSnapshot) -> String {
    if let title = snapshot.title?.nonEmpty {
        return title
    }
    if let project = snapshot.projectName?.nonEmpty {
        return "\(noNameYet) in \(project)"
    }
    return noNameYet
}
