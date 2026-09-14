import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchCore

/// What a live agent process is worth on the widget before anything has been heard from it,
/// and what happens when it finally speaks.
final class DiscoveredProcessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A copy sent to the background with `/bg` can be running before this app hears a hook
    /// from it, and the scanner then builds its row. That row has to say the same thing the
    /// sender would — background, no window, a click attaches — or the click on it looks for a
    /// window that does not exist while `claude attach` would have worked.
    func testARowBuiltFromAProcessCarriesTheKindOfPlaceTheScannerSaw() {
        let inTheAgentsPty = DiscoveredAgentProcess(
            source: .claude, processID: 502, startedAt: Date(timeIntervalSince1970: 100), projectName: "x",
            clientKind: .background)
        XCTAssertEqual(inTheAgentsPty.row(arrivalIndex: 0).clientKind, .background)

        let inATerminal = DiscoveredAgentProcess(
            source: .claude, processID: 501, startedAt: Date(timeIntervalSince1970: 100), projectName: "x")
        XCTAssertEqual(inATerminal.row(arrivalIndex: 0).clientKind, .cli, "the ordinary answer stands by default")
    }

    /// The case the whole feature exists for: the app was not running when the agent
    /// started, so no hook is coming until the session takes another turn — and a session
    /// waiting for a person may never take one.
    func testALiveAgentWithNoHooksBecomesARow() throws {
        var engine = SessionStateEngine()

        let change = engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now - 900)])

        XCTAssertEqual(change.added.map(\.id), ["claude:process-501-1699999100"])
        let row = try XCTUnwrap(engine.snapshots["claude:process-501-1699999100"])
        XCTAssertEqual(row.phase, .disconnected, "nothing has been heard, and the row must not claim otherwise")
        XCTAssertEqual(row.projectName, "agent-watch")
        XCTAssertEqual(row.lastObservedAt, now - 900, "the age a process can prove is its own")
        XCTAssertEqual(row.agentProcessID, 501)
        XCTAssertNil(row.title, "a name is something only the agent can give")
    }

    /// A row that claimed work would be reported as an unexplained silence within two
    /// minutes — a warning triangle on every discovered row, always wrong.
    func testADiscoveredRowRaisesNoAlarmAndIsNeverReadFor() throws {
        var engine = SessionStateEngine()
        engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now - 86_400)])
        let row = try XCTUnwrap(engine.snapshots.values.first)

        XCTAssertFalse(SessionSilence.isUnexplained(row, now: now))
        XCTAssertTrue(
            SessionSilence.isExpected(row),
            "an expected silence is what keeps the transcript reader away from a synthetic label"
        )
    }

    /// Running the scan again must not pile up rows, and an agent that quit must not leave
    /// one behind — the exit watch is the first line, this is the backstop for a Mac that
    /// slept through it.
    func testTheSecondScanAddsNothingAndAVanishedProcessLeaves() {
        var engine = SessionStateEngine()
        let running = [process(id: 501, startedAt: now - 900), process(id: 502, startedAt: now - 60)]

        XCTAssertEqual(engine.reconcileDiscoveredProcesses(running).added.count, 2)
        XCTAssertTrue(engine.reconcileDiscoveredProcesses(running).isEmpty)

        let change = engine.reconcileDiscoveredProcesses([running[0]])
        XCTAssertEqual(change.removedIDs, ["claude:process-502-1699999940"])
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// macOS hands process numbers out again. Keyed on the number alone a row would survive
    /// its own process, wearing a stranger's age.
    func testTheSameNumberWithANewStartTimeIsANewRow() {
        var engine = SessionStateEngine()
        engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now - 900)])

        let change = engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now - 5)])

        XCTAssertEqual(change.removedIDs, ["claude:process-501-1699999100"])
        XCTAssertEqual(change.added.map(\.id), ["claude:process-501-1699999995"])
        XCTAssertEqual(engine.snapshots.count, 1, "one process is one row, whatever its number has been before")
    }

    /// The join the plan asks for. Two rows for one agent is the failure this prevents, and
    /// the place in the list is kept so the row does not vanish from under the pointer and
    /// reappear at the bottom.
    func testTheFirstHookTakesOverTheRowBuiltFromItsProcess() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(sessionLabel: "earlier", agentProcessID: nil))
        engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now - 900)])
        let discoveredIndex = try XCTUnwrap(engine.snapshots["claude:process-501-1699999100"]?.arrivalIndex)

        let arriving = event(sessionLabel: "abc", agentProcessID: 501)
        let claimed = engine.claimDiscoveredRow(for: arriving)
        let session = try engine.ingest(arriving)

        XCTAssertEqual(claimed?.id, "claude:process-501-1699999100")
        XCTAssertNil(engine.snapshots["claude:process-501-1699999100"])
        XCTAssertEqual(session.arrivalIndex, discoveredIndex, "the session takes the place its process held")
        XCTAssertEqual(engine.snapshots.count, 2)
    }

    /// A process a hook once named is not an anonymous process any more. The row it makes is
    /// the session itself — which is what lets the row be asked the questions a session can
    /// answer, starting with which file it writes and therefore what it is called.
    func testAProcessKnownToBeASessionMakesThatSessionsRow() throws {
        var engine = SessionStateEngine()

        let change = engine.reconcileDiscoveredProcesses([
            process(id: 501, startedAt: now - 900).knowing(sessionLabel: "abc")
        ])

        XCTAssertEqual(change.added.map(\.id), ["claude:abc"])
        let row = try XCTUnwrap(engine.snapshots["claude:abc"])
        XCTAssertEqual(row.phase, .disconnected, "recognising a session is not hearing from it")
        XCTAssertEqual(row.agentProcessID, 501)
    }

    /// The hook such a row has been waiting for. There is nothing to hand over — the row
    /// already is this session — and everything the row had collected in the meantime stays,
    /// starting with the name its own transcript gave it.
    func testAHookForARowThatIsAlreadyItsSessionKeepsWhatTheRowHas() throws {
        var engine = SessionStateEngine()
        engine.reconcileDiscoveredProcesses([
            process(id: 501, startedAt: now - 900).knowing(sessionLabel: "abc")
        ])
        engine.applyDescription(
            SessionDescription(title: "read from its own transcript"), toSessionWithID: "claude:abc")
        let arriving = event(sessionLabel: "abc", agentProcessID: 501)

        XCTAssertNil(engine.claimDiscoveredRow(for: arriving), "there is no other row to take the place of")
        let session = try engine.ingest(arriving)

        XCTAssertEqual(session.title, "read from its own transcript")
        XCTAssertNil(
            session.discoveredProcess,
            "a session that has spoken for itself is no longer a row built from a process — and the file keeps it"
        )
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// A resumed session is the one case where a claimed row's place is reserved and never
    /// spent: `claude --resume` keeps the session's identifier and gives it a new process,
    /// so the session already exists when the row built from that new process is handed
    /// over. The reservation then outlived the process it was filed under — and macOS hands
    /// those numbers out again, so the next session to land on that number stepped into the
    /// place of a row that had been gone for hours, appearing in the middle of the list
    /// instead of at its end.
    func testAResumedSessionLeavesNoPlaceBehindForTheNextAgent() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(sessionLabel: "abc", agentProcessID: 501))
        // Resumed: the same session, a new process, which had a row of its own by then.
        engine.reconcileDiscoveredProcesses([process(id: 777, startedAt: now - 60)])
        let resumed = event(sessionLabel: "abc", agentProcessID: 777)
        engine.claimDiscoveredRow(for: resumed)
        try engine.ingest(resumed)
        let laterSession = try engine.ingest(event(sessionLabel: "later", agentProcessID: 502))

        // Long after, that process number belongs to somebody else entirely.
        let newcomer = try engine.ingest(event(sessionLabel: "zzz", agentProcessID: 777))

        XCTAssertGreaterThan(
            newcomer.arrivalIndex,
            laterSession.arrivalIndex,
            "a session nobody has seen before joins at the end of the list, not in the middle"
        )
    }

    /// Once a session knows its own process number, a scan that finds that process again is
    /// looking at the same session from outside. A second row would be the same agent twice.
    func testAProcessASessionAlreadyClaimsGetsNoRowOfItsOwn() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(sessionLabel: "abc", agentProcessID: 501))

        let change = engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now - 900)])

        XCTAssertTrue(change.isEmpty)
        XCTAssertEqual(engine.snapshots.count, 1)
    }

    /// A closed session under "remove closed sessions by hand" never retires, so it would
    /// hold its process number for good — and macOS hands those out again. Counting it as a
    /// claim would leave the next agent to land on that number with no row at all, and
    /// nothing to clear it.
    func testATombstoneDoesNotHoldOntoAProcessNumberForever() throws {
        var engine = SessionStateEngine()
        try engine.ingest(event(sessionLabel: "abc", agentProcessID: 501))
        engine.markSessionClosed(id: "claude:abc", at: now)

        let change = engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now)])

        XCTAssertEqual(change.added.map(\.id), ["claude:process-501-1700000000"])
    }

    /// The next launch looks for the process itself. Remembered, the row could only come
    /// back for an agent that has since exited.
    func testADiscoveredRowIsNeverRemembered() {
        var engine = SessionStateEngine()
        engine.reconcileDiscoveredProcesses([process(id: 501, startedAt: now - 900)])

        XCTAssertEqual(SessionHistory.records(of: Array(engine.snapshots.values)), [])
    }

    /// A field added to a shared snapshot is a field the memory file will be asked to carry.
    /// It is optional so that a file written before it existed still reads: the decoder fails
    /// open, and one throw would have emptied the file on the first launch of a new build.
    func testAMemoryWrittenBeforeThisFieldExistedStillReads() throws {
        let json = """
            {"id":"claude:abc","source":"claude","arrivalIndex":3,"mode":"unknown",
             "phase":"disconnected","activities":[],"lastObservedAt":0}
            """

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.id, "claude:abc")
        XCTAssertNil(decoded.discoveredProcess)
    }

    private func process(id: Int32, startedAt: Date) -> DiscoveredAgentProcess {
        DiscoveredAgentProcess(
            source: .claude,
            processID: id,
            startedAt: startedAt,
            projectName: "agent-watch"
        )
    }

    private func event(sessionLabel: String, agentProcessID: Int32?) -> EventEnvelope {
        testEvent(sessionLabel: sessionLabel, observedAt: now, agentProcessID: agentProcessID)
    }
}
