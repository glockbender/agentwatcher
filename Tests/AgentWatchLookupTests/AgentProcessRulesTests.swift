import AgentWatchCore
import XCTest

@testable import AgentWatchLookup

/// What an agent cannot tell is answered with nothing by its own rules, rather than by an
/// `if source == .claude` in each caller that remembered to ask.
final class AgentProcessRulesTests: XCTestCase {
    /// Codex run from inside a Claude session — by the agent's own shell tool, say — has the
    /// Claude process among its hook's ancestors. That process is not Codex's session, and a
    /// Codex hook naming it would hand a Codex row the exit and the terminal of a Claude one.
    func testACodexHookInsideAClaudeSessionNamesNoProcessAndNoOriginal() {
        let ancestors = [
            ProcessSnapshot(processID: 700, executableName: "codex", executablePath: "/opt/homebrew/bin/codex"),
            ProcessSnapshot(processID: 600, executableName: "zsh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "2.1.282",
                executablePath: "/private/opaque/claude/versions/2.1.282"
            ),
        ]
        let claudeFork = [
            "/private/opaque/claude/versions/2.1.282", "--session-id", "b95a16c1-0000", "--fork-session",
            "--resume", "ab007d7a-0000",
        ]

        XCTAssertEqual(AgentSource.claude.processRules.agentProcessID(among: ancestors), 400)
        XCTAssertNil(AgentSource.codex.processRules.agentProcessID(among: ancestors))
        XCTAssertNil(
            AgentSource.codex.processRules.forkedFromSessionID(arguments: claudeFork, forSessionID: "b95a16c1-0000")
        )
        XCTAssertEqual(
            AgentProcessLocator.clientKind(for: .codex, in: ancestors, argumentsOfProcess: { _ in nil }),
            .cli
        )
    }

    /// Codex's processes do not count its sessions — one desktop process holds many threads —
    /// so no row is ever built from one.
    func testCodexSessionsAreNeverFoundFromProcesses() {
        XCTAssertEqual(AgentSource.codex.processRules.liveSessions(), [])
    }
}
