/// How many sessions are in each of the four states a person acts on.
///
/// A value rather than four properties, and `Equatable` for one reason: what reads it draws
/// the menu bar icon, and that drawing happens only when this changes. Sessions move
/// constantly without moving any of these numbers — a call starts, a title arrives, a
/// transcript grows — and each of those would otherwise be a redraw with nothing new in it.
///
/// Closed sessions are counted nowhere, so the four numbers need not add up to the list they
/// came from. See ADR-0002.
public struct SessionAttentionCounts: Equatable, Sendable {
    public let needsPerson: Int
    public let working: Int
    public let done: Int
    public let quiet: Int

    public static let empty = SessionAttentionCounts(needsPerson: 0, working: 0, done: 0, quiet: 0)

    public init(needsPerson: Int, working: Int, done: Int, quiet: Int) {
        self.needsPerson = needsPerson
        self.working = working
        self.done = done
        self.quiet = quiet
    }

    public init(sessions: [SessionSnapshot]) {
        var needsPerson = 0
        var working = 0
        var done = 0
        var quiet = 0
        for session in sessions {
            switch session.phase.attention {
            case .needsPerson: needsPerson += 1
            case .working: working += 1
            case .done: done += 1
            case .quiet: quiet += 1
            case .closed: break
            }
        }
        self.init(needsPerson: needsPerson, working: working, done: done, quiet: quiet)
    }

    /// How many sessions were counted at all — which is not how many there are.
    public var counted: Int {
        needsPerson + working + done + quiet
    }
}
