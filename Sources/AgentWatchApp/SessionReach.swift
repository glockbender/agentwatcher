/// Whether a click on a session's row has anything to bring forward.
///
/// It used to be `SessionLocator`, a value naming the application, the project window and the
/// terminal tab — three answers, because the hover card spelled out where a click would land.
/// That line is gone: a click that works needs no sentence (§8 of the architecture). What the
/// card still needs is the one case worth saying out loud, and this is the question it asks.
///
/// Cases and not a `Bool`: `nowhere` reads at the call site as a fact about the session,
/// where `false` reads only as something not being true — and the third case is a click that
/// does something else entirely.
///
/// Optional where it is passed, and `nil` is not `nowhere`: one means nobody asked, the other
/// means somebody asked and the answer was no.
enum SessionReach: Equatable, Sendable {
    /// An application holds the session, and a click raises it.
    case anApplication
    /// Nothing does — the host has quit, or the session never had a window of its own.
    case nowhere
    /// The session's terminal was closed and its agent hangs without it, and a click ends
    /// the agent through this device — `nil` when no descriptor of the agent's names one,
    /// and then the click has nothing to do. The device stays out of the session model: it
    /// is the process's, read at the moment the card or the click asks.
    case closedTerminal(devicePath: String?)
}
