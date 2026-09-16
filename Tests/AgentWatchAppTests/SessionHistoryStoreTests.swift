import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// Real files, because the point is a widget that is not empty after a restart.
@MainActor
final class SessionHistoryStoreTests: XCTestCase {
    private let moment = Date(timeIntervalSince1970: 1_700_000_000)

    /// Everything describing the session survives; everything describing what it was doing
    /// does not. The reduction happens on the way to disk, so the file cannot hold a phase
    /// for anything to trust later.
    func testTheSessionsOfOneLaunchAreRememberedByTheNext() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var working = testSession(
            phase: .executing,
            activities: [SessionActivity(id: "call-1", kind: .shell, startedAt: moment)],
            lastObservedAt: moment
        )
        working.projectName = "agent-watch"
        working.modelName = "claude-opus-5"

        SessionHistoryStore(directoryURL: directory).update([working], at: moment)

        let remembered = SessionHistoryStore(directoryURL: directory).remembered
        XCTAssertEqual(remembered.map(\.id), [working.id])
        XCTAssertEqual(remembered.first?.projectName, "agent-watch")
        XCTAssertEqual(remembered.first?.modelName, "claude-opus-5")
        XCTAssertEqual(remembered.first?.lastObservedAt, moment)
        XCTAssertEqual(remembered.first?.phase, .disconnected)
        XCTAssertEqual(remembered.first?.activities, [])
    }

    /// A closed session is deliberately forgotten. It cannot be restored honestly — its host
    /// is gone, so nothing could vouch for the row — and a tombstone from the previous launch
    /// is not what an empty widget is missing.
    func testAClosedSessionIsNotRemembered() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let working = testSession(index: 0, phase: .executing, lastObservedAt: moment)
        let closed = testSession(index: 1, phase: .sessionClosed, lastObservedAt: moment)

        SessionHistoryStore(directoryURL: directory).update([working, closed], at: moment)

        XCTAssertEqual(SessionHistoryStore(directoryURL: directory).remembered.map(\.id), [working.id])
    }

    /// A wait is the one part of a phase the file keeps, and it is worth nothing if it waits
    /// out the write window: the app going away seconds after a session asked its person is
    /// exactly the case a restart has to survive.
    func testASessionThatStartsWaitingIsWrittenAtOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionHistoryStore(directoryURL: directory)
        var session = testSession(phase: .executing, lastObservedAt: moment)
        store.update([session], at: moment)

        session.phase = .waitingForUser
        session.setAwaitedDialogs([AwaitedDialog(activityID: "call-1", kind: .approval)])
        // A second later: well inside the window that an age or a model name would wait out.
        store.update([session], at: moment + 1)

        let remembered = try XCTUnwrap(SessionHistoryStore(directoryURL: directory).remembered.first)
        XCTAssertEqual(remembered.phase, .waitingForUser)
        XCTAssertEqual(remembered.unansweredDialogs.first?.activityID, "call-1")
        XCTAssertEqual(remembered.userInputRequestKind, .approval)
    }

    /// A second dialog is as much a change as the first, and the file has to take it at
    /// once for the same reason.
    ///
    /// Two subagents can be asked at the same moment — measured — and neither question need
    /// name a call this app ever heard of. Told apart by the awaited call alone, as the file
    /// once was, the second dialog opening looked like no change at all and waited out the
    /// write window.
    func testASecondDialogOpeningIsWrittenAtOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionHistoryStore(directoryURL: directory)
        var session = testSession(phase: .waitingForUser, lastObservedAt: moment)
        let first = AwaitedDialog(agentID: "reviewer-a", kind: .approval)
        session.setAwaitedDialogs([first])
        store.update([session], at: moment)

        session.setAwaitedDialogs([first, AwaitedDialog(agentID: "reviewer-b", kind: .approval)])
        store.update([session], at: moment + 1)

        let remembered = try XCTUnwrap(SessionHistoryStore(directoryURL: directory).remembered.first)
        XCTAssertEqual(remembered.unansweredDialogs.map(\.agentID), ["reviewer-a", "reviewer-b"])
    }

    /// And the way out of a wait is written at once for the same reason: a file still saying
    /// "waiting for you" about a session that has been answered is the wrong half of the same
    /// mistake.
    func testASessionThatStopsWaitingIsWrittenAtOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionHistoryStore(directoryURL: directory)
        var session = testSession(phase: .waitingForUser, lastObservedAt: moment)
        session.setAwaitedDialogs([AwaitedDialog(activityID: "call-1", kind: .approval)])
        store.update([session], at: moment)

        session.phase = .executing
        session.clearAwaited()
        store.update([session], at: moment + 1)

        XCTAssertEqual(SessionHistoryStore(directoryURL: directory).remembered.first?.phase, .disconnected)
    }

    /// The age moves on nearly every event, several times a minute, and being a minute behind
    /// on it costs a restored row a minute of apparent silence. So it is written now and then
    /// rather than on every publish.
    func testAnAgeThatMovedInsideTheWindowLeavesTheFileAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionHistoryStore(directoryURL: directory)
        var session = testSession(phase: .executing, lastObservedAt: moment)

        store.update([session], at: moment)
        XCTAssertEqual(try storedAges(in: directory), [moment])

        session.lastObservedAt = moment + 5
        store.update([session], at: moment + 5)
        XCTAssertEqual(try storedAges(in: directory), [moment], "still the first write")

        session.lastObservedAt = moment + 90
        store.update([session], at: moment + 90)
        XCTAssertEqual(try storedAges(in: directory), [moment + 90], "and past the window it is written")
    }

    /// The exception to the window, and the direction that would do real damage: a session
    /// that ended a second before the app was quit must not be waiting in the file when it
    /// starts again.
    func testASessionLeavingIsWrittenWithoutWaitingForTheWindow() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionHistoryStore(directoryURL: directory)
        let first = testSession(index: 0, phase: .executing, lastObservedAt: moment)
        let second = testSession(index: 1, phase: .executing, lastObservedAt: moment)

        store.update([first, second], at: moment)
        store.update([second], at: moment + 1)

        XCTAssertEqual(
            SessionHistoryStore(directoryURL: directory).remembered.map(\.id),
            [second.id]
        )
    }

    /// Fail open, like every other read of a file this app did not just write. A file
    /// somebody edited, one a full disk truncated, or one written by a version whose sessions
    /// had a field this one has not: the cost is an empty widget for one restart, and it must
    /// never be the launch.
    func testAFileThatCannotBeUnderstoodRemembersNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("sessions-remembered.json"))

        let store = SessionHistoryStore(directoryURL: directory)

        XCTAssertEqual(store.remembered, [])

        let session = testSession(phase: .executing, lastObservedAt: moment)
        store.update([session], at: moment)
        XCTAssertEqual(
            SessionHistoryStore(directoryURL: directory).remembered.map(\.id),
            [session.id],
            "and the ruined file is replaced by a usable one"
        )
    }

    /// A file written before the pairings existed still gives back its sessions.
    ///
    /// It did not once, and the cost was every remembered row on the launch that upgraded.
    /// The sessions are the valuable part of this file: a list added later must never be able
    /// to take them down with it.
    func testAFileWrittenBeforeTheNewListStillGivesBackItsSessions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = testSession(phase: .executing, lastObservedAt: moment)
        // Written by hand in the older shape: sessions, and no key for anything else.
        let older = try JSONEncoder().encode([session])
        try Data(#"{"sessions":"#.utf8 + older + #"}"#.utf8)
            .write(to: directory.appendingPathComponent("sessions-remembered.json"))

        let store = SessionHistoryStore(directoryURL: directory)

        XCTAssertEqual(store.remembered.map(\.id), [session.id])
        XCTAssertEqual(store.rememberedAgentProcesses, [], "nothing was written, so nothing is known")
    }

    /// And a file written before a wait could name more than one dialog gives back its
    /// sessions too — with no wait rather than a guessed one.
    ///
    /// The same rule as the pairings above and the same cost if it breaks: every remembered
    /// row on the launch that upgrades. Which is why the field is optional; a required one
    /// would have thrown here and taken the whole file with it. The wait itself does not come
    /// back: the older file says who was asked in keys this version no longer reads, and a
    /// wait restored without its owner is the bug the owner exists to stop.
    func testAFileWrittenBeforeDialogsWereAListStillGivesBackItsSessions() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = testSession(phase: .waitingForUser, lastObservedAt: moment)
        session.setAwaitedDialogs([AwaitedDialog(activityID: "call-1", kind: .approval)])

        // The older shape: the two flat fields the wait used to be, and no list.
        var older = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        XCTAssertNotNil(
            older.removeValue(forKey: "awaitedDialogs"),
            "the key has to be there to be taken away, or this test proves nothing"
        )
        older["awaitedActivityID"] = "call-1"
        try JSONSerialization.data(withJSONObject: ["sessions": [older]])
            .write(to: directory.appendingPathComponent("sessions-remembered.json"))

        let store = SessionHistoryStore(directoryURL: directory)

        XCTAssertEqual(store.remembered.map(\.id), [session.id])
        XCTAssertEqual(store.remembered.first?.phase, .waitingForUser, "the file's own claim survives")
        XCTAssertEqual(store.remembered.first?.unansweredDialogs, [], "and names nobody it cannot name")
    }

    /// Read out of the file rather than off the object, because what is under test is whether
    /// the file was rewritten at all.
    private func storedAges(in directory: URL) throws -> [Date] {
        SessionHistoryStore(directoryURL: directory).remembered.map(\.lastObservedAt)
    }

    private func makeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }
}
