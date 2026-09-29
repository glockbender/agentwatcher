import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// Which sessions the menu lists, in what order, and what each line says.
final class MenuSessionLinesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testOnlyTheChosenStatesAreListed() {
        let lines = menuSessionLines(
            for: [
                session(0, .waitingForUser),
                session(1, .executing),
                session(2, .completed),
                session(3, .idle),
            ],
            listing: [.needsPerson, .done],
            reach: { _ in .anApplication }
        )

        XCTAssertEqual(lines.map(\.sessionID), [id(0), id(2)])
        XCTAssertEqual(lines.map(\.attention), [.needsPerson, .done])
    }

    /// The order is the widget's, handed over already made: the lines add none of their own.
    func testLinesKeepTheOrderTheyAreHanded() {
        let sessions = [session(2, .completed), session(0, .failed), session(1, .waitingForUser)]

        let lines = menuSessionLines(for: sessions, listing: Set(SessionAttention.counted), reach: { _ in .nowhere })

        XCTAssertEqual(lines.map(\.sessionID), [id(2), id(0), id(1)])
    }

    /// ADR-0002: over is over. Not even a hand-edited setting that names `closed` lists one.
    func testAClosedSessionIsNeverListed() {
        let lines = menuSessionLines(
            for: [session(0, .sessionClosed), session(1, .completed)],
            listing: Set(SessionAttention.allCases),
            reach: { _ in .anApplication }
        )

        XCTAssertEqual(lines.map(\.sessionID), [id(1)])
    }

    func testNothingChosenListsNothing() {
        XCTAssertEqual(
            menuSessionLines(for: [session(0, .waitingForUser)], listing: [], reach: { _ in .anApplication }),
            []
        )
    }

    /// The name the widget's row would show, falling back the way the row does.
    func testALineIsNamedTheWayTheRowIs() {
        let lines = menuSessionLines(
            for: [
                testSession(index: 0, title: "Port the probe", phase: .completed, lastObservedAt: now),
                testSession(index: 1, title: nil, projectName: "agent-watch", phase: .completed, lastObservedAt: now),
                testSession(index: 2, title: "", projectName: nil, phase: .completed, lastObservedAt: now),
            ],
            listing: [.done],
            reach: { _ in .anApplication }
        )

        XCTAssertEqual(
            lines.map(\.title),
            ["Port the probe", "\(noNameYet) in agent-watch", noNameYet]
        )
        XCTAssertEqual(lines.map(\.isEnabled), [true, true, true])
    }

    /// The one click in the app that ends something. The widget's card says so before the
    /// click; a menu line has no card, so the line itself has to.
    func testALineWhoseClickEndsTheAgentSaysSo() {
        let lines = menuSessionLines(
            for: [
                testSession(index: 0, title: "Left behind", phase: .terminalClosed, lastObservedAt: now)
            ],
            listing: [.needsPerson],
            reach: { _ in .closedTerminal(.discardOutput(devicePath: "/dev/ttys004")) }
        )

        XCTAssertEqual(lines.map(\.title), ["Left behind — terminal closed, click ends the agent"])
        XCTAssertEqual(lines.map(\.isEnabled), [true])
    }

    /// A tab Ghostty closed and kept is ended differently and said the same way: the person
    /// closed a terminal either way, and the line is about what the click does.
    func testALineWhoseClickHangsUpTheAgentSaysTheSame() {
        let lines = menuSessionLines(
            for: [
                testSession(index: 0, title: "Left behind", phase: .terminalClosed, lastObservedAt: now)
            ],
            listing: [.needsPerson],
            reach: { _ in .closedTerminal(.hangUp(processID: 52671)) }
        )

        XCTAssertEqual(lines.map(\.title), ["Left behind — terminal closed, click ends the agent"])
        XCTAssertEqual(lines.map(\.endingAgentWasAnnounced), [true])
    }

    /// Nothing to end it with, so the click would do nothing: the line stays, greyed, and says
    /// why rather than disappearing.
    func testALineWhoseClickCouldDoNothingIsGreyedAndSaysWhy() {
        let lines = menuSessionLines(
            for: [
                testSession(index: 0, title: "Left behind", phase: .terminalClosed, lastObservedAt: now)
            ],
            listing: [.needsPerson],
            reach: { _ in .closedTerminal(nil) }
        )

        XCTAssertEqual(lines.map(\.title), ["Left behind — terminal closed, nothing here can end it"])
        XCTAssertEqual(lines.map(\.isEnabled), [false])
    }

    /// Asking where a session is walks the process tree, and the menu opens often. Only a
    /// closed terminal changes what a line says, so only that session is asked about.
    func testOnlyAClosedTerminalIsAskedWhereItIs() {
        var asked: [String] = []

        _ = menuSessionLines(
            for: [session(0, .waitingForUser), session(1, .terminalClosed), session(2, .completed)],
            listing: Set(SessionAttention.counted),
            reach: { snapshot in
                asked.append(snapshot.id)
                return .closedTerminal(.discardOutput(devicePath: "/dev/ttys004"))
            }
        )

        XCTAssertEqual(asked, [id(1)])
    }

    private func session(_ index: Int, _ phase: SessionPhase) -> SessionSnapshot {
        testSession(index: index, phase: phase, lastObservedAt: now)
    }

    private func id(_ index: Int) -> String {
        "claude:session-\(index)"
    }
}
