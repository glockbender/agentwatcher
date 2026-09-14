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
    /// has its row — the background one, and a click on it is what opens the attach to begin
    /// with. A row for the viewer too would be nameless, would never hear a hook of its own,
    /// and would stand beside the row it duplicates. The earlier reading — "a session, in a
    /// window somebody can be sent to" — is kept the other way round: a click on the
    /// background row is what finds that window. Measured: the kernel hands the words back
    /// one by one.
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
        XCTAssertEqual(
            AgentProcessLocator.commandWords(["/Volumes/My Disk/.local/bin/claude", "daemon", "run"]),
            ["daemon", "run"],
            "a path is one word however many spaces it has; only a renamed process carries words in the program's place"
        )
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

    /// A session sent to the background with `/bg` keeps running in a fresh `claude` started
    /// by the agent's pty host, and that host is the parent, not the session's own command.
    /// Measured on 2.1.269: the host runs from `ClaudeCode.app`, not from `versions/`, and
    /// names itself by a flag — `claude --bg-pty-host …` — so neither the executable rule nor
    /// the first-word rule saw it, and the session was reported as a terminal one with no
    /// terminal anywhere above it.
    func testASessionUnderTheAgentsPtyHostIsReportedAsBackground() {
        let ancestors = [
            ProcessSnapshot(
                processID: 16222,
                executableName: "2.1.269",
                executablePath: "/private/opaque/claude/versions/2.1.269"
            ),
            ProcessSnapshot(
                processID: 16043,
                executableName: "claude",
                executablePath: "/private/opaque/claude/ClaudeCode.app/Contents/MacOS/claude"
            ),
        ]
        let arguments: [Int32: [String]] = [
            16222: [
                "/private/opaque/claude/versions/2.1.269", "--session-id", "b95a16c1-0000", "--fork-session",
                "--resume", "/private/opaque/projects/x/ab007d7a-0000.jsonl", "--permission-mode", "auto",
            ],
            16043: [
                "/private/opaque/claude/ClaudeCode.app/Contents/MacOS/claude", "--bg-pty-host",
                "/private/opaque/pty/b95a16c1.sock", "86", "79", "--", "/private/opaque/claude/versions/2.1.269",
            ],
        ]

        XCTAssertEqual(
            AgentProcessLocator.clientKind(for: .claude, in: ancestors, argumentsOfProcess: { arguments[$0] }),
            .background
        )
        // The renamed shape the host had in earlier builds is still a host.
        XCTAssertEqual(
            AgentProcessLocator.clientKind(
                for: .claude,
                in: ancestors,
                argumentsOfProcess: {
                    $0 == 16043
                        ? ["claude bg-pty-host", "--bg-pty-host", "/private/opaque/pty/b95a16c1.sock"] : arguments[$0]
                }
            ),
            .background
        )
    }

    /// `/bg` continues a session in a new process under a new identifier, and the only place
    /// the old identifier survives is the process's own arguments: `--fork-session` says it
    /// is a copy, and `--resume` names the transcript it was copied from, whose file is named
    /// after the session. Measured on 2.1.269; no hook field carries it.
    ///
    /// The copy's process runs a second, two-second session first — the one `--resume`
    /// always leaves behind — and its hooks read the same arguments. Only the session the
    /// process was started for, named by `--session-id`, is the copy; the stub is nobody's
    /// continuation, and saying otherwise would put its start and end on the original's row.
    func testAForkNamesTheSessionItContinuesForTheSessionItWasStartedFor() {
        let launchedByClaude = [
            "/private/opaque/claude/versions/2.1.269", "--session-id", "b95a16c1-0000", "--fork-session",
            "--resume", "/private/opaque/projects/x/ab007d7a-9ae2-4888-8b57-2920b3cc1bb9.jsonl",
            "--permission-mode", "auto",
        ]
        XCTAssertEqual(
            AgentProcessLocator.forkedFromSessionID(arguments: launchedByClaude, forSessionID: "b95a16c1-0000"),
            "ab007d7a-9ae2-4888-8b57-2920b3cc1bb9"
        )
        XCTAssertNil(
            AgentProcessLocator.forkedFromSessionID(arguments: launchedByClaude, forSessionID: "stub-0000"),
            "the two-second session the resume leaves behind continues nothing"
        )
        // Every spelling of `--resume` Claude Code passes, read the same way.
        for spelling in [
            ["--session-id", "b95a16c1-0000", "--fork-session", "--resume", "ab007d7a-9ae2-4888-8b57-2920b3cc1bb9"],
            ["--session-id", "b95a16c1-0000", "--fork-session", "-r", "ab007d7a-9ae2-4888-8b57-2920b3cc1bb9"],
            ["--session-id", "b95a16c1-0000", "--fork-session", "--resume=ab007d7a-9ae2-4888-8b57-2920b3cc1bb9"],
        ] {
            XCTAssertEqual(
                AgentProcessLocator.forkedFromSessionID(
                    arguments: ["claude"] + spelling, forSessionID: "b95a16c1-0000"),
                "ab007d7a-9ae2-4888-8b57-2920b3cc1bb9",
                "\(spelling)"
            )
        }
        // Typed by a person, without the `--session-id` Claude Code always passes: nothing
        // here can tell the copy from the stub `--resume` leaves behind on the same process,
        // and guessing costs more than it saves. Read as a copy, the stub would join the
        // original's row, reset it on its start and close it on its end two seconds later; a
        // copy read as nobody's is one extra row, which the person can see and this cannot.
        for typed in [
            ["claude", "--resume", "ab007d7a-9ae2-4888-8b57-2920b3cc1bb9", "--fork-session"],
            ["claude", "-r", "ab007d7a-9ae2-4888-8b57-2920b3cc1bb9", "--fork-session"],
            ["claude", "--fork-session", "--resume=ab007d7a-9ae2-4888-8b57-2920b3cc1bb9"],
        ] {
            XCTAssertNil(
                AgentProcessLocator.forkedFromSessionID(arguments: typed, forSessionID: "any"),
                "\(typed)"
            )
        }
        // A plain resume keeps its identifier, so there is nothing to continue from.
        XCTAssertNil(
            AgentProcessLocator.forkedFromSessionID(
                arguments: ["claude", "--resume", "/private/opaque/projects/x/ab007d7a-0000.jsonl"], forSessionID: "any"
            )
        )
        // A fork with nothing to fork from, and a resume that names nothing, say nothing.
        for empty in [["claude", "--fork-session"], ["claude", "--fork-session", "--resume"], ["claude"]] {
            XCTAssertNil(AgentProcessLocator.forkedFromSessionID(arguments: empty, forSessionID: "any"), "\(empty)")
        }
    }

    /// The words that name one of the agent's helpers are ordinary words, and a process far
    /// above the session may have been started with them for reasons of its own: `emacs
    /// --daemon` is the usual way to run Emacs, and a terminal inside it is the parent of
    /// every command typed there. Only Claude's own processes are asked the question, which
    /// is what «helper of the agent's» means — otherwise a perfectly ordinary session in such
    /// a terminal would be called a background one, and a click on it would open a door
    /// instead of raising the window it does have.
    func testAnAncestorOfItsOwnWithAHelpersWordInItIsNotTheAgentsHelper() {
        let ancestors = [
            ProcessSnapshot(
                processID: 600,
                executableName: "claude",
                executablePath: "/private/opaque/claude/versions/2.1.269"
            ),
            ProcessSnapshot(processID: 500, executableName: "zsh", executablePath: "/bin/zsh"),
            ProcessSnapshot(processID: 400, executableName: "emacs", executablePath: "/opt/homebrew/bin/emacs"),
        ]
        let arguments: [Int32: [String]] = [
            600: ["/private/opaque/claude/versions/2.1.269"],
            500: ["-zsh"],
            400: ["/opt/homebrew/bin/emacs", "--daemon"],
        ]

        XCTAssertEqual(
            AgentProcessLocator.clientKind(for: .claude, in: ancestors, argumentsOfProcess: { arguments[$0] }),
            .cli
        )
    }

    /// A helper renames itself in the builds measured so far, so its own name says it is
    /// Claude's — but the file it runs from is called after a version number, and a helper
    /// that did not rename itself would be Claude's by that path alone. Both answers count,
    /// or the day a helper stops renaming itself every background session is called a
    /// terminal one.
    func testAHelperIsTheAgentsByItsPathAsWellAsByItsName() {
        let ancestors = [
            ProcessSnapshot(
                processID: 600,
                executableName: "claude",
                executablePath: "/private/opaque/claude/versions/2.1.269"
            )
        ]

        XCTAssertEqual(
            AgentProcessLocator.clientKind(
                for: .claude,
                in: ancestors,
                argumentsOfProcess: { _ in
                    ["/private/opaque/claude/versions/2.1.269", "bg-spare", "--bg-spare", "/private/opaque/claim.sock"]
                }
            ),
            .background
        )
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
