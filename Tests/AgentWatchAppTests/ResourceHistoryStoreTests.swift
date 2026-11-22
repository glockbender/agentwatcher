import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// A closed session keeps its peak memory and CPU time across a restart.
@MainActor
final class ResourceHistoryStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testASessionThatEndsIsWrittenAndReadBackByTheNextLaunch() throws {
        let folder = try scratchFolder()
        let store = ResourceHistoryStore(directoryURL: folder)
        let session = measuredSession()
        store.sessionsChanged([session])
        store.add(reading(of: session, footprint: 612 << 20))
        XCTAssertFalse(fileExists(in: folder), "an open session's figures wait for its end")

        var closed = session
        closed.phase = .sessionClosed
        store.sessionsChanged([closed])

        let next = ResourceHistoryStore(directoryURL: folder)
        XCTAssertEqual(next.history.records[session.id]?.peakFootprint, 612 << 20)
    }

    /// A row dismissed while its agent still runs has ended for the widget, and is written too.
    func testARowThatLeavesTheListIsWritten() throws {
        let folder = try scratchFolder()
        let store = ResourceHistoryStore(directoryURL: folder)
        let session = measuredSession()
        store.sessionsChanged([session])
        store.add(reading(of: session, footprint: 1 << 20))

        store.sessionsChanged([])

        XCTAssertTrue(fileExists(in: folder))
    }

    func testQuittingWritesTheOpenSessions() throws {
        let folder = try scratchFolder()
        let store = ResourceHistoryStore(directoryURL: folder)
        let session = measuredSession()
        store.sessionsChanged([session])
        store.add(reading(of: session, footprint: 1 << 20))

        store.save()

        XCTAssertNotNil(ResourceHistoryStore(directoryURL: folder).history.records[session.id])
    }

    private func measuredSession() -> SessionSnapshot {
        var session = testSession(phase: .executing, lastObservedAt: now)
        session.agentProcessID = 100
        return session
    }

    private func reading(of session: SessionSnapshot, footprint: UInt64) -> ResourceReport {
        ResourceAttribution.report(
            table: ProcessTable(
                sampledAt: now,
                processes: [SampledProcess(processID: 100, parentProcessID: 1, name: "claude", footprint: footprint)]),
            sessions: [session],
            previous: nil)
    }

    private func fileExists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("session-resources.json").path)
    }

    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchResourceHistory.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
