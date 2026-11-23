import AgentWatchCore
import XCTest

/// What a closed session keeps: its peak memory and the CPU time the readings saw.
final class ResourceHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let megabyte: UInt64 = 1 << 20

    func testThePeakIsTheLargestReadingAndCPUTimeAddsUpEachInterval() throws {
        let session = row("a", processID: 100)
        var history = ResourceHistory()
        var previous: ResourceReport?
        // Footprint rises and falls; the agent uses 1 s of CPU in the first 5 s and 3 s in the next.
        for (seconds, footprint, cpu) in [(0.0, 300, 10.0), (5, 900, 11), (10, 400, 14)] as [(Double, UInt64, Double)] {
            let report = reading(
                of: [session], footprint: footprint * megabyte, cpuTime: cpu, at: seconds, after: previous)
            history.add(report)
            previous = report
        }

        let record = try XCTUnwrap(history.records[session.id])
        XCTAssertEqual(record.peakFootprint, 900 * megabyte)
        XCTAssertEqual(record.cpuTime, 4, accuracy: 0.001, "the first reading has no load to count from")
        XCTAssertEqual(record.lastSeenAt, start.addingTimeInterval(10))
    }

    /// Watching switched off and on again: the reading after it has no previous one, and the time
    /// in between, which nobody watched, is not counted.
    func testAReadingWithNoPreviousOneAddsNoTime() {
        let session = row("a", processID: 100)
        var history = ResourceHistory()
        let first = reading(of: [session], footprint: megabyte, cpuTime: 10, at: 0, after: nil)
        history.add(first)
        history.add(reading(of: [session], footprint: megabyte, cpuTime: 500, at: 3600, after: nil))

        XCTAssertEqual(history.records[session.id]?.cpuTime, 0)
    }

    func testTheRecordsSeenLongestAgoGoFirst() {
        var history = ResourceHistory(limit: 2)
        for (index, label) in ["a", "b", "c"].enumerated() {
            history.add(
                reading(
                    of: [row(label, processID: 100)], footprint: megabyte, cpuTime: 0, at: Double(index), after: nil))
        }

        XCTAssertEqual(Set(history.records.keys), [row("b", processID: 100).id, row("c", processID: 100).id])
    }

    func testARecordSurvivesTheTripThroughAFile() throws {
        let record = SessionResourceRecord(peakFootprint: 612 * megabyte, cpuTime: 42.5, lastSeenAt: start)
        let decoded = try JSONDecoder().decode(
            SessionResourceRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    private func reading(
        of sessions: [SessionSnapshot],
        footprint: UInt64,
        cpuTime: TimeInterval,
        at seconds: TimeInterval,
        after previous: ResourceReport?
    ) -> ResourceReport {
        ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: start.addingTimeInterval(seconds),
                processes: [
                    SampledProcess(
                        processID: 100, parentProcessID: 1, name: "claude", footprint: footprint, cpuTime: cpuTime)
                ]),
            sessions: sessions,
            previous: previous)
    }

    private func row(_ label: String, processID: Int32) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionSnapshot.id(source: .claude, sessionLabel: label),
            source: .claude,
            arrivalIndex: 0,
            phase: .idle,
            lastObservedAt: start,
            agentProcessID: processID
        )
    }
}
