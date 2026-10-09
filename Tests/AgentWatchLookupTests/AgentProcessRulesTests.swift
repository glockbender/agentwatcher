import AgentWatchCore
import XCTest

@testable import AgentWatchLookup

/// What an agent cannot tell is answered with nothing by its own rules, rather than by an
/// `if source == .claude` in each caller that remembered to ask.
final class AgentProcessRulesTests: XCTestCase {
    /// Codex run from inside a Claude session — by the agent's own shell tool, say — has the
    /// Claude process among its hook's ancestors. That process is not Codex's session, and a
    /// Codex hook naming it would hand a Codex row the exit and the terminal of a Claude one:
    /// Codex names its own.
    func testACodexHookInsideAClaudeSessionNamesItsOwnProcessAndNoOriginal() {
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
        XCTAssertEqual(AgentSource.codex.processRules.agentProcessID(among: ancestors), 700)
        XCTAssertNil(
            AgentSource.codex.processRules.forkedFromSessionID(arguments: claudeFork, forSessionID: "b95a16c1-0000")
        )
        XCTAssertEqual(
            AgentProcessLocator.clientKind(for: .codex, in: ancestors, argumentsOfProcess: { _ in nil }),
            .cli
        )
    }

    /// A `codex exec` run holds one thread and nothing else, so its own process is named: the
    /// nearest `codex` above the hook, and never the Claude session that started the run.
    /// Measured on Codex 0.153.4, where the hook is that process's child or its shell's.
    func testAHeadlessCodexRunNamesItsOwnProcess() {
        let ancestors = [
            ProcessSnapshot(processID: 800, executableName: "zsh", executablePath: "/bin/zsh"),
            ProcessSnapshot(
                processID: 700, executableName: "codex",
                executablePath: "/opt/homebrew/Caskroom/codex/0.153.4/bin/codex"),
            ProcessSnapshot(processID: 600, executableName: "zsh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "2.1.289",
                executablePath: "/private/opaque/claude/versions/2.1.289"
            ),
        ]

        XCTAssertEqual(AgentSource.codex.processRules.headlessRunProcessID(among: ancestors), 700)
    }

    /// Codex in a terminal holds one thread at a time, and its hooks are the `codex`
    /// process's own children. Measured on Codex 0.161.0.
    func testACodexThreadInATerminalNamesItsOwnProcess() {
        let ancestors = [
            ProcessSnapshot(
                processID: 700, executableName: "codex",
                executablePath: "/opt/homebrew/Caskroom/codex/0.161.0/bin/codex"),
            ProcessSnapshot(processID: 600, executableName: "zsh", executablePath: "/bin/zsh"),
            ProcessSnapshot(
                processID: 500, executableName: "ghostty",
                executablePath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
        ]

        XCTAssertEqual(AgentSource.codex.processRules.agentProcessID(among: ancestors), 700)
    }

    /// The desktop application holds every thread in one process, so its number would be
    /// every thread's at once — and its exit would close them all together.
    func testACodexThreadInTheDesktopApplicationNamesNoProcess() {
        let ancestors = [
            ProcessSnapshot(
                processID: 43_860, executableName: "codex",
                executablePath:
                    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ),
            ProcessSnapshot(
                processID: 43_643, executableName: "ChatGPT",
                executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
        ]

        XCTAssertNil(AgentSource.codex.processRules.agentProcessID(among: ancestors))
        XCTAssertEqual(
            AgentProcessLocator.clientKind(for: .codex, in: ancestors, argumentsOfProcess: { _ in nil }),
            .desktop
        )
    }

    /// Codex's processes do not count its sessions — one desktop process holds many threads —
    /// so no row is ever built from one.
    func testCodexSessionsAreNeverFoundFromProcesses() {
        XCTAssertEqual(AgentSource.codex.processRules.liveSessions(), [])
    }
}
