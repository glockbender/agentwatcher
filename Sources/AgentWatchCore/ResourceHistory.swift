import Foundation

/// What a session used while Agent Watch watched it: the most memory at once, and the CPU time.
///
/// A closed session has no live numbers, so this is what is left to show for it
/// (`docs/proposals/resource-usage.md`, «Где показывать»). Counted only while watching is on,
/// and only from what the readings saw: a session that ran for an hour before watching was
/// switched on reports the time since.
public struct SessionResourceRecord: Codable, Equatable, Sendable {
    /// Bytes of footprint, the largest any reading gave the session (ADR-0024).
    public var peakFootprint: UInt64
    /// Seconds of CPU: each reading's load times the time since the reading before it.
    public var cpuTime: TimeInterval
    /// The last reading that held the session. Old records go first when the history is pruned.
    public var lastSeenAt: Date

    public init(peakFootprint: UInt64, cpuTime: TimeInterval, lastSeenAt: Date) {
        self.peakFootprint = peakFootprint
        self.cpuTime = cpuTime
        self.lastSeenAt = lastSeenAt
    }
}

/// Every session's record, kept from reading to reading and across restarts.
///
/// Apart from the session's snapshot on purpose: a figure that moves every five seconds would make
/// every row look changed, and the widget rebuilds a row only when its snapshot does.
public struct ResourceHistory: Equatable, Sendable {
    /// How many records the history keeps by default: room for every open session and for a
    /// few days of closed ones.
    public static let defaultLimit = 500

    public private(set) var records: [String: SessionResourceRecord]
    private let limit: Int
    /// When the last reading was taken: a load is cores, and the time since this turns it into
    /// seconds of CPU.
    private var lastSampledAt: Date?

    public init(records: [String: SessionResourceRecord] = [:], limit: Int = defaultLimit) {
        self.records = records
        self.limit = limit
    }

    /// Takes one reading in.
    ///
    /// A reading's load is the CPU time spent since the reading before it, divided by the time
    /// between them, so load times that time is the CPU time itself. A reading with no load — the
    /// first after launch, or after watching was switched back on — adds memory only, so the
    /// time watching was off is never counted.
    public mutating func add(_ report: ResourceReport) {
        let interval = lastSampledAt.map { report.sampledAt.timeIntervalSince($0) } ?? 0
        lastSampledAt = report.sampledAt
        for session in report.sessions.values {
            var record =
                records[session.sessionID]
                ?? SessionResourceRecord(peakFootprint: 0, cpuTime: 0, lastSeenAt: report.sampledAt)
            record.peakFootprint = max(record.peakFootprint, session.total.footprint)
            if let load = session.cpuLoad, interval > 0 {
                record.cpuTime += load * interval
            }
            record.lastSeenAt = report.sampledAt
            records[session.sessionID] = record
        }
        prune()
    }

    /// Drops the records seen longest ago, past `limit`.
    private mutating func prune() {
        guard records.count > limit else {
            return
        }
        let oldest = records.sorted { $0.value.lastSeenAt < $1.value.lastSeenAt }.prefix(records.count - limit)
        for (id, _) in oldest {
            records[id] = nil
        }
    }
}
