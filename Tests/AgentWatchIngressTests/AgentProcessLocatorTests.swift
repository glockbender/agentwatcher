import XCTest

@testable import AgentWatchSender

final class AgentProcessLocatorTests: XCTestCase {
    func testFindsClaudeProcessAmongHookShellAncestors() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "claude",
                executablePath: "/private/opaque/claude/versions/claude"
            ),
            ProcessSnapshot(processID: 300, executableName: "zsh"),
            ProcessSnapshot(processID: 200, executableName: "goland"),
        ]

        XCTAssertEqual(AgentProcessLocator.findClaudeProcessID(in: ancestors), 400)
    }

    func testDoesNotTreatAnUnrelatedAncestorAsClaude() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(processID: 300, executableName: "zsh"),
            ProcessSnapshot(processID: 200, executableName: "goland"),
        ]

        XCTAssertNil(AgentProcessLocator.findClaudeProcessID(in: ancestors))
    }

    func testDoesNotTrustAnAncestorNamedClaudeWithoutAnInstallationPath() {
        let ancestors = [
            ProcessSnapshot(processID: 400, executableName: "claude")
        ]

        XCTAssertNil(AgentProcessLocator.findClaudeProcessID(in: ancestors))
    }

    func testFindsVersionedClaudeExecutableFromItsInstallationLayout() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "2.1.257",
                executablePath: "/private/opaque/claude/versions/2.1.257"
            ),
            ProcessSnapshot(processID: 300, executableName: "zsh"),
        ]

        XCTAssertEqual(AgentProcessLocator.findClaudeProcessID(in: ancestors), 400)
    }

    func testDoesNotTreatAnArbitraryVersionedExecutableAsClaude() {
        let ancestors = [
            ProcessSnapshot(
                processID: 500,
                executableName: "2.1.257",
                executablePath: "/private/opaque/not-claude/versions/2.1.257"
            )
        ]

        XCTAssertNil(AgentProcessLocator.findClaudeProcessID(in: ancestors))
    }

    func testClassifiesClaudeHookAsCLIWithoutSendingItsHostPath() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "2.1.257",
                executablePath: "/private/opaque/claude/versions/2.1.257"
            ),
        ]

        XCTAssertEqual(AgentProcessLocator.clientKind(for: .claude, in: ancestors), .cli)
    }

    func testClassifiesCodexDesktopFromItsTrustedApplicationBundle() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "codex",
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex"
            ),
        ]

        XCTAssertEqual(AgentProcessLocator.clientKind(for: .codex, in: ancestors), .desktop)
    }

    func testClassifiesCodexCLIOnlyWhenTheExecutableIsNotTheDesktopBundle() {
        let ancestors = [
            ProcessSnapshot(
                processID: 400,
                executableName: "codex",
                executablePath: "/opt/homebrew/Caskroom/codex/0.140.0/codex-aarch64-apple-darwin"
            )
        ]

        XCTAssertEqual(AgentProcessLocator.clientKind(for: .codex, in: ancestors), .cli)
    }

    /// The one call here that reads the kernel's own struct rather than a list a test built,
    /// so the layout is worth exercising for real. A PID above the system's maximum belongs to
    /// nobody and never will, which is the case a naive `sysctl` gets wrong: it succeeds and
    /// fills in nothing, so only the returned size tells the two apart.
    func testAProcessStartTimeIsReadForALivePIDAndRefusedForOneNobodyHolds() throws {
        let startedAt = try XCTUnwrap(AgentProcessLocator.startTime(of: getpid()))

        XCTAssertLessThanOrEqual(startedAt, Date())
        XCTAssertGreaterThan(startedAt, Date(timeIntervalSince1970: 1_000_000_000))
        XCTAssertNil(AgentProcessLocator.startTime(of: 999_999))
    }

    /// The argument probe, read against a process that certainly exists: this one. The
    /// kernel's answer is the test runner's own command line, and it has to come back whole
    /// — the count, the skipped executable path and the NUL-separated words are all parsed
    /// by hand, and a mistake in any of them would make a session look like a helper.
    func testAProcessesOwnArgumentsAreReadWholeAndADeadPIDHasNone() throws {
        let arguments = try XCTUnwrap(AgentProcessLocator.commandArguments(of: getpid()))

        XCTAssertEqual(arguments, CommandLine.arguments)
        XCTAssertNil(AgentProcessLocator.commandArguments(of: 999_999))
    }

    // MARK: - Helpers of the agent, which are not sessions

    /// Measured on a running machine: Claude Code keeps several long-lived processes of its
    /// own, all from the executable a session runs. Each one became a row with no name, no
    /// window to focus and no hook ever coming.
    func testTheAgentsOwnHelpersAreNotSessions() {
        XCTAssertTrue(
            AgentProcessLocator.isHelperCommand([
                "/private/opaque/.local/bin/claude", "daemon", "run", "--origin", "transient",
            ])
        )
        XCTAssertTrue(
            AgentProcessLocator.isHelperCommand([
                "claude bg-pty-host", "--bg-pty-host", "/private/opaque/spare.pty.sock", "200", "50",
            ]),
            "a helper renames itself, so its job is written into the first argument rather than the second"
        )
        XCTAssertTrue(
            AgentProcessLocator.isHelperCommand(["claude bg-spare", "--bg-spare", "/private/opaque/claim.sock"])
        )
    }

    /// `claude attach` shows a background session in this terminal, and that session already
    /// has its row — the background one, whose `↗` is what opens the attach to begin with. A
    /// row for the viewer too would be nameless, would never hear a hook of its own, and would
    /// stand beside the row it duplicates. The earlier reading — "a session, in a window
    /// somebody can be sent to" — is kept the other way round: the background row's press is
    /// what finds that window. Measured: the kernel hands the words back one by one.
    func testAViewerAttachedToABackgroundSessionIsNotASecondSession() {
        XCTAssertTrue(AgentProcessLocator.isHelperCommand(["claude", "attach", "3345bfdf"]))
        XCTAssertTrue(AgentProcessLocator.isHelperCommand(["claude attach 3345bfdf"]))
    }

    /// One reading for both shapes the kernel reports — the words after the program, whether
    /// the program renamed itself into them or not — because two rules ask it: whether a
    /// process is a helper, and whether a viewer of one particular session is running.
    func testTheWordsAfterTheProgramAreReadTheSameWayInBothShapes() {
        XCTAssertEqual(AgentProcessLocator.commandWords(["claude", "attach", "3345bfdf"]), ["attach", "3345bfdf"])
        XCTAssertEqual(AgentProcessLocator.commandWords(["claude attach 3345bfdf"]), ["attach", "3345bfdf"])
        XCTAssertEqual(AgentProcessLocator.commandWords(["/private/opaque/.local/bin/claude"]), [])
        XCTAssertEqual(AgentProcessLocator.commandWords([]), [])
    }

    func testASessionIsNotMistakenForAHelper() {
        XCTAssertFalse(AgentProcessLocator.isHelperCommand(["claude"]))
        XCTAssertFalse(AgentProcessLocator.isHelperCommand(["claude", "--resume"]))
        XCTAssertFalse(
            AgentProcessLocator.isHelperCommand(["claude", "daemon of the lamp, explain yourself"]),
            "a prompt is one argument, and the word it starts with is not a subcommand"
        )
        XCTAssertFalse(AgentProcessLocator.isHelperCommand([]))
    }

    /// Claude Code runs a background session inside a helper of its own, and the widget has
    /// to know: a session there has no window, now or later.
    func testASessionInTheAgentsOwnPtyIsReportedAsBackground() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "zsh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "claude",
                executablePath: "/private/opaque/claude/versions/2.1.268"
            ),
        ]

        XCTAssertEqual(
            AgentProcessLocator.clientKind(
                for: .claude,
                in: ancestors,
                argumentsOfProcess: { _ in ["claude bg-spare", "--bg-spare", "/private/opaque/claim.sock"] }
            ),
            .background
        )
        XCTAssertEqual(
            AgentProcessLocator.clientKind(for: .claude, in: ancestors, argumentsOfProcess: { _ in ["claude"] }),
            .cli
        )
        XCTAssertEqual(
            AgentProcessLocator.clientKind(for: .claude, in: ancestors, argumentsOfProcess: { _ in nil }),
            .cli,
            "a kernel that will not say what the process was started with leaves the ordinary answer standing"
        )
    }
}
