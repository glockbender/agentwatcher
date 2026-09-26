import Foundation

/// The four blocks a list of sessions can be cut into, top to bottom as a person arranges
/// them.
public enum SessionBlock: String, CaseIterable, Sendable {
    /// Alive, in any phase, and either at work at some point or new enough to still be.
    case active
    /// Never had a turn, and silent long enough to say nobody is coming to give it one.
    case neverStarted
    /// Stopped by something going wrong: a failed turn, a lost signal, a terminal closed under
    /// a running agent.
    case broken
    /// Over.
    case closed

    /// The order a fresh install shows them in: what a person is working with, then what they
    /// opened and left, then what went wrong, then what is finished.
    public static let defaultOrder: [SessionBlock] = [.active, .neverStarted, .broken, .closed]

    /// The block a session is in at this moment.
    ///
    /// The silence that drops a session that never worked out of the active ones is the one
    /// its `×` waits for, from the same function: the owner asked for one rule, and one
    /// moment keeps the widget to one timer.
    public static func of(_ snapshot: SessionSnapshot, now: Date) -> SessionBlock {
        switch snapshot.phase {
        case .sessionClosed:
            return .closed
        // A failed turn is also what the icon counts as needing a person. In blocks it goes
        // with the other two things that went wrong, as the owner chose.
        case .failed, .disconnected, .terminalClosed:
            return .broken
        case .idle, .planning, .executing, .waitingForUser, .waitingForChildren, .completed:
            break
        }
        guard !snapshot.hasWorked, now >= SessionPresence.silenceEnds(for: snapshot) else {
            return .active
        }
        return .neverStarted
    }

    /// Every block exactly once, in the stored order where the file gives one.
    ///
    /// A name this version does not know, or one given twice, is skipped; a block the file
    /// leaves out goes back in at its place in the default order. Leaving it out would take its
    /// sessions out of the widget, and a sort must never do that.
    public static func normalized(_ stored: [String]) -> [SessionBlock] {
        var blocks: [SessionBlock] = []
        for block in stored.compactMap(SessionBlock.init(rawValue:)) where !blocks.contains(block) {
            blocks.append(block)
        }
        return blocks + defaultOrder.filter { !blocks.contains($0) }
    }
}

/// How a list of sessions is ordered.
public enum SessionOrder: String, CaseIterable, Sendable {
    /// In the order the app first saw them, closed ones last. Rows never move by themselves.
    case arrival
    /// By the icon's groups — needs you, working, done, idle, closed — and within a group the
    /// session that joined it last first.
    case attention
    /// Whatever was heard from last first, closed ones last. The busiest list of the four.
    case recentActivity
    /// By `SessionBlock`, in the order a person arranged the blocks, and within a block the
    /// session that joined it last first.
    case blocks
}

/// Orders sessions, and remembers what the order needs to: when each joined its group.
///
/// "The latest to join a group comes first" needs a memory, because a snapshot does not say
/// when its phase changed — only when it was last heard from. So each session's group is kept
/// together with a number that grows with every change seen, and a list is ordered by those.
/// Numbers rather than times: two sessions can never tie, and a change is placed by when this
/// saw it, which is what the list on screen did.
///
/// One value, ordered from wherever the list is shown, keeps the widget and the menu in one
/// order. Asking again with the same sessions changes nothing.
public struct SessionOrdering: Sendable {
    private struct Membership: Sendable {
        let group: String
        let sequence: Int
    }

    private var memberships: [String: Membership] = [:]
    private var nextSequence = 0

    public init() {}

    public mutating func order(
        _ sessions: [SessionSnapshot],
        mode: SessionOrder,
        blocks: [SessionBlock],
        now: Date
    ) -> [SessionSnapshot] {
        switch mode {
        case .arrival:
            return Self.closedLast(sessions.sorted(by: Self.byArrival))
        case .recentActivity:
            return Self.closedLast(
                sessions.sorted { left, right in
                    left.lastObservedAt != right.lastObservedAt
                        ? left.lastObservedAt > right.lastObservedAt
                        : Self.byArrival(left, right)
                })
        case .attention:
            let groups = SessionAttention.allCases.map(\.rawValue)
            return grouped(sessions, groups: groups, now: now) { snapshot, _ in snapshot.phase.attention.rawValue }
        case .blocks:
            return grouped(sessions, groups: blocks.map(\.rawValue), now: now) { snapshot, now in
                SessionBlock.of(snapshot, now: now).rawValue
            }
        }
    }

    /// The order a list already on screen keeps while a person is pointing at it.
    ///
    /// Rows shown before keep their places relative to each other; a session that has arrived
    /// since goes to the end, where it moves nothing; one that is gone simply leaves. The
    /// widget asks for this while the pointer is over it, and the real order once it leaves.
    public static func holdingPlaces(of shownIDs: [String], in ordered: [SessionSnapshot]) -> [SessionSnapshot] {
        let place = Dictionary(shownIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = ordered.compactMap { snapshot in place[snapshot.id].map { (snapshot, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return kept + ordered.filter { place[$0.id] == nil }
    }

    /// Groups in the order given, and within a group by when each session joined it, latest
    /// first.
    ///
    /// A group is remembered by its name, not by where it stands: moving a block in the list
    /// changes where its sessions are shown, not when each of them joined it.
    private mutating func grouped(
        _ sessions: [SessionSnapshot],
        groups: [String],
        now: Date,
        group: (SessionSnapshot, Date) -> String
    ) -> [SessionSnapshot] {
        var rank: [String: Int] = [:]
        for (place, name) in groups.enumerated() where rank[name] == nil {
            rank[name] = place
        }
        let members = sessions.map { Member(snapshot: $0, group: group($0, now)) }
        record(members, now: now)
        let placed: [Placed] = members.map { member in
            Placed(
                snapshot: member.snapshot,
                rank: rank[member.group] ?? groups.count,
                sequence: memberships[member.snapshot.id]?.sequence ?? 0
            )
        }
        return placed.sorted(by: Placed.comesFirst).map(\.snapshot)
    }

    private struct Member {
        let snapshot: SessionSnapshot
        let group: String
    }

    private struct Placed {
        let snapshot: SessionSnapshot
        let rank: Int
        let sequence: Int

        static func comesFirst(_ left: Placed, _ right: Placed) -> Bool {
            left.rank != right.rank ? left.rank < right.rank : left.sequence > right.sequence
        }
    }

    /// Notes every session whose group is not the one it was last seen in, and forgets the
    /// sessions that are gone.
    ///
    /// Several found in a new group at once are numbered by when each most likely got there —
    /// the moment its silence ran out for a drop by time alone, its last event otherwise — so
    /// sessions that changed while nobody was looking still come out in the order they changed.
    private mutating func record(_ members: [Member], now: Date) {
        let present = Set(members.map(\.snapshot.id))
        memberships = memberships.filter { present.contains($0.key) }
        let joined = members.filter { memberships[$0.snapshot.id]?.group != $0.group }
        let inOrder = joined.sorted { left, right in
            Self.joinedEarlier(left.snapshot, right.snapshot, now: now)
        }
        for member in inOrder {
            memberships[member.snapshot.id] = Membership(group: member.group, sequence: nextSequence)
            nextSequence += 1
        }
    }

    private static func joinedEarlier(_ left: SessionSnapshot, _ right: SessionSnapshot, now: Date) -> Bool {
        let leftMoment = likelyJoined(left, now: now)
        let rightMoment = likelyJoined(right, now: now)
        guard leftMoment == rightMoment else {
            return leftMoment < rightMoment
        }
        return byArrival(left, right)
    }

    private static func likelyJoined(_ snapshot: SessionSnapshot, now: Date) -> Date {
        SessionBlock.of(snapshot, now: now) == .neverStarted
            ? SessionPresence.silenceEnds(for: snapshot)
            : snapshot.lastObservedAt
    }

    private static func byArrival(_ left: SessionSnapshot, _ right: SessionSnapshot) -> Bool {
        left.arrivalIndex < right.arrivalIndex
    }

    /// A closed session is finished, and retention is about to remove it anyway.
    private static func closedLast(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
        sessions.filter { $0.phase != .sessionClosed } + sessions.filter { $0.phase == .sessionClosed }
    }
}
