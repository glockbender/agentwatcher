import AgentWatchCore
import AgentWatchIngress
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// The way hook events get into the app: a local socket, and the rules for what arrives on
/// it. Those rules used to live in `AppDelegate`, which cannot be built in a test, so none of
/// them had ever been exercised — including the one that matters most, that a listener which
/// cannot start leaves the app running.
@MainActor
final class HookIngressControllerTests: XCTestCase {
    /// Fail-open, and the reason `AGENTS.md` insists on it: the app watches agents, and an
    /// app that refuses to start because it cannot watch them has made their problem worse.
    func testAListenerThatCannotStartLeavesTheAppRunningAndSaysSo() {
        var logged: [String] = []
        let controller = HookIngressController(
            socketURL: { nil },
            ingest: { _ in
                XCTFail("nothing can arrive through a listener that never started")
                return nil
            },
            reveal: { XCTFail("nothing arrived") },
            log: { logged.append($0) }
        )

        controller.start()

        XCTAssertEqual(logged, ["Local hook listener is unavailable"])
    }

    /// The other way a listener fails: a path it cannot bind. A Unix socket path is limited to
    /// 104 bytes on macOS, so a longer one is refused by the system, not by this code.
    func testAListenerThatCannotBindItsSocketLeavesTheAppRunningAndSaysSo() {
        var logged: [String] = []
        let tooLong = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(repeating: "x", count: 120))
            .appendingPathComponent("agent-watch.sock")
        let controller = HookIngressController(
            socketURL: { tooLong },
            ingest: { _ in
                XCTFail("nothing can arrive through a listener that never started")
                return nil
            },
            reveal: { XCTFail("nothing arrived") },
            log: { logged.append($0) }
        )

        controller.start()

        XCTAssertEqual(logged, ["Local hook listener is unavailable"])
    }

    func testAnAcceptedEventIsHandedOverAndNamedInTheLog() {
        var ingested: [HookIngressRequest] = []
        var logged: [String] = []
        let controller = makeController(
            ingest: { request in
                ingested.append(request)
                return testEvent(sessionLabel: "id_session", kind: .turnStarted, observedAt: .now)
            },
            log: { logged.append($0) }
        )

        controller.handle(.success(hookRequest()))

        XCTAssertEqual(ingested.count, 1)
        XCTAssertEqual(logged, ["Claude · id_session · turnStarted"])
    }

    func testAMalformedEventIsRefusedWithoutReachingTheSessions() {
        var logged: [String] = []
        let controller = makeController(
            ingest: { _ in
                XCTFail("a malformed request must not reach the sessions")
                return nil
            },
            log: { logged.append($0) }
        )

        controller.handle(.failure(.malformedMessage))

        XCTAssertEqual(logged, ["Rejected malformed local hook event"])
    }

    /// An event the app understands the shape of but can make nothing of. It is still refused,
    /// and still said out loud: the debug log is where an integration that sends the wrong
    /// thing is found.
    func testAnEventTheAppCanMakeNothingOfIsRefusedOutLoud() {
        var logged: [String] = []
        let controller = makeController(ingest: { _ in nil }, log: { logged.append($0) })

        controller.handle(.success(hookRequest()))

        XCTAssertEqual(logged, ["Rejected unsupported local hook event"])
    }

    /// The one message on this socket that is not an event: a second copy of the app asking
    /// the first to show itself.
    func testTheRevealMessageShowsTheAppInsteadOfBecomingASession() {
        var revealed = 0
        let controller = makeController(
            ingest: { _ in
                XCTFail("the reveal message is not a session event")
                return nil
            },
            reveal: { revealed += 1 }
        )

        controller.handle(.success(LocalAgentWatchControl.revealExistingInstanceRequest()))

        XCTAssertEqual(revealed, 1)
    }

    private func makeController(
        ingest: @escaping (HookIngressRequest) -> EventEnvelope?,
        reveal: @escaping () -> Void = {},
        log: @escaping (String) -> Void = { _ in }
    ) -> HookIngressController {
        HookIngressController(socketURL: { nil }, ingest: ingest, reveal: reveal, log: log)
    }

    private func hookRequest() -> HookIngressRequest {
        HookIngressRequest(
            source: .claude,
            declaredEvent: "UserPromptSubmit",
            payload: .object(["session_id": .string("id_session")])
        )
    }
}
