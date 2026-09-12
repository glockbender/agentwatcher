import XCTest

@testable import AgentWatchCore

final class ToolingIntegrationTests: XCTestCase {
    /// `PostToolUse` is deliberately not asked for, from either agent.
    ///
    /// It is the one hook that buys nothing a person can see. Closing an activity is all it
    /// does, and two other things already close one: the transcript reader turns a
    /// `tool_result` record into the same fact, and the end of a turn sweeps every activity
    /// that does not outlive it. What the hook adds is freshness — a finished call leaves the
    /// row a few seconds sooner — and it charges a process launch per tool call for that,
    /// 0.78 s on the machine this was measured on, which doubles the cost of a `Read`.
    ///
    /// So the trade was refused rather than offered as a switch: a switch nobody would turn
    /// on is machinery to maintain, and the app was describing a choice it gave no way to make.
    func testNeitherAgentIsAskedForPostToolUse() {
        for source in AgentSource.allCases {
            XCTAssertFalse(
                ToolingHooks.hooks(for: source).contains("PostToolUse"),
                "\(source) is asked for PostToolUse, which costs a process launch per tool call"
            )
        }
    }

    /// The sender lives in `~/Library/Application Support/AgentWatch/`, and both agents run a
    /// hook through a shell. An unquoted path with a space in it is therefore two words: the
    /// shell tried to run `/Users/…/Library/Application` and answered `No such file or
    /// directory`, exit 127 — measured live, in a session whose hooks had just been
    /// reinstalled. Every hook failed, silently, because a failing hook is fail-open by
    /// design; the widget simply never heard from that session again.
    func testTheHookCommandNamesTheSenderAsOneWordForAShell() throws {
        let senderPath = "/Users/someone/Library/Application Support/AgentWatch/AgentWatchSend"

        let document = ToolingInstallation.addingOurHooks(
            to: .object([:]),
            source: .claude,
            senderPath: senderPath,
            hooks: ["Stop"]
        )

        XCTAssertEqual(
            try command(inHooks: document, event: "Stop"),
            "'\(senderPath)' --source claude --event Stop"
        )
        XCTAssertEqual(
            ToolingInstallation.senderPaths(inHooks: document, source: .claude)["Stop"],
            senderPath,
            "and the app reads back the path, not the quotes around it"
        )
    }

    /// Entries an earlier version wrote carry no quotes, and they have to stay recognisable as
    /// ours. Otherwise a reinstall would leave them in place and add its own beside them —
    /// every hook firing twice, at a process launch each.
    func testAnUnquotedEntryFromAnEarlierVersionIsStillOurs() {
        let senderPath = "/Users/someone/Library/Application Support/AgentWatch/AgentWatchSend"
        let asWrittenBefore = JSONValue.object([
            "hooks": .object([
                "Stop": .array([
                    .object([
                        "hooks": .array([
                            .object([
                                "type": .string("command"),
                                "command": .string("\(senderPath) --source claude --event Stop"),
                            ])
                        ])
                    ])
                ])
            ])
        ])

        XCTAssertEqual(
            ToolingInstallation.senderPaths(inHooks: asWrittenBefore, source: .claude)["Stop"],
            senderPath
        )

        let reinstalled = ToolingInstallation.addingOurHooks(
            to: asWrittenBefore,
            source: .claude,
            senderPath: senderPath,
            hooks: ["Stop"]
        )

        guard case let .object(root) = reinstalled, case let .object(events)? = root["hooks"],
            case let .array(groups)? = events["Stop"]
        else {
            return XCTFail("Expected one group of hooks for Stop")
        }
        XCTAssertEqual(groups.count, 1, "the old entry was replaced, not joined by a second one")
    }

    /// The command written for one event, as a shell would receive it.
    private func command(inHooks document: JSONValue, event: String) throws -> String {
        guard case let .object(root) = document, case let .object(events)? = root["hooks"],
            case let .array(groups)? = events[event], case let .object(group)? = groups.first,
            case let .array(entries)? = group["hooks"], case let .object(entry)? = entries.first,
            case let .string(command)? = entry["command"]
        else {
            XCTFail("no command written for \(event)")
            throw CocoaError(.coderInvalidValue)
        }
        return command
    }

    /// The two lists must not drift. A hook asked for but not understood pays a process
    /// launch for nothing; the reverse — an event understood but never asked for — is a fact
    /// silently lost. This catches the first, which is the one a person cannot see.
    func testEveryHookAskedForIsOneTheProtocolUnderstands() {
        for source in AgentSource.allCases {
            for event in ToolingHooks.hooks(for: source) {
                let request = HookIngressRequest(
                    source: source,
                    declaredEvent: event,
                    payload: .object([
                        "session_id": .string("a-session"),
                        "tool_use_id": .string("a-call"),
                        "tool_name": .string("Bash"),
                        "agent_id": .string("a-subagent"),
                    ])
                )

                XCTAssertNoThrow(
                    try HookIngressProcessor.normalize(request, observedAt: Date()),
                    "\(source) asks for \(event), which the protocol refuses"
                )
            }
        }
    }

    /// The gap the neighbouring test names and cannot see: an event the agent offers and this
    /// app never asks for is a fact lost with nothing to report it.
    ///
    /// The catalogue is written by hand because it is knowledge about somebody else's
    /// product, and that is the point: it makes the next divergence a failing test with a
    /// diff to review instead of a silence nobody notices.
    ///
    /// `declined` is what keeps the rule usable. Not asking for an event has to be a decision
    /// somebody wrote down, or this test turns every deliberate omission into a failure and
    /// the next person makes it pass by asking for the event again.
    func testCodexIsAskedForEveryEventCodexOffersAndDeclinesOnlyOnPurpose() {
        let offered: Set<String> = [
            "SessionStart", "SessionEnd",
            "UserPromptSubmit", "Stop", "Interrupt",
            "PreToolUse", "PostToolUse", "PermissionRequest",
            "SubagentStart", "SubagentStop",
            "PreCompact", "PostCompact",
        ]
        // Closing an activity, which the transcript and the end of a turn already do, for the
        // price of a process launch per tool call. See `testNeitherAgentIsAskedForPostToolUse`.
        let declined: Set<String> = ["PostToolUse"]
        let asked = Set(ToolingHooks.hooks(for: .codex))

        XCTAssertEqual(
            offered.subtracting(declined).subtracting(asked),
            [],
            "Codex reports these and nobody is listening"
        )
        XCTAssertEqual(
            asked.subtracting(offered),
            [],
            "asking for an event Codex does not have pays a process launch for nothing"
        )
        XCTAssertEqual(asked.intersection(declined), [], "a declined event must stay declined")
    }

    /// The plugin carries the whole registration. Claude Code loads a personal plugin from
    /// `~/.claude/skills/`, hooks included, so nothing has to be written into the settings
    /// file a person maintains by hand.
    func testThePluginFileRegistersEachHookAgainstTheSender() {
        let document = ClaudeHookPlugin.hooksDocument(
            senderPath: "/Applications/AgentWatch.app/Contents/MacOS/AgentWatchSend",
            hooks: ["SessionStart", "Stop"]
        )

        XCTAssertEqual(
            document,
            .object([
                "hooks": .object([
                    "SessionStart": Self.expectedEntry(event: "SessionStart"),
                    "Stop": Self.expectedEntry(event: "Stop"),
                ])
            ])
        )
    }

    /// Written and read back by the same rules, so the two halves cannot drift apart. The
    /// path matters as much as the event: it is what tells an installation that still works
    /// from one pointing at a sender that is gone.
    func testAHooksDocumentReadsBackAsTheEventsAndTheSenderTheyName() {
        let document = ClaudeHookPlugin.hooksDocument(
            senderPath: "/A/AgentWatchSend",
            hooks: ["SessionStart", "Stop"]
        )

        XCTAssertEqual(
            ToolingInstallation.senderPaths(inHooks: document, source: .claude),
            ["SessionStart": "/A/AgentWatchSend", "Stop": "/A/AgentWatchSend"]
        )
    }

    /// Someone else's hook is not ours to count, to report on, or ever to remove.
    func testAHookBelongingToSomebodyElseIsNotRead() {
        let document = JSONValue.object([
            "hooks": .object([
                "PreToolUse": .array([
                    .object([
                        "matcher": .string("Bash"),
                        "hooks": .array([
                            .object([
                                "type": .string("command"),
                                "command": .string("bash /Users/someone/.claude/hooks/git-guard.sh"),
                            ])
                        ]),
                    ])
                ])
            ])
        ])

        XCTAssertTrue(ToolingInstallation.senderPaths(inHooks: document, source: .claude).isEmpty)
    }

    func testAConfigurationWithNoneOfOurEntriesReadsAsNotInstalled() {
        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: [:],
                hooks: ToolingHooks.hooks(for: .claude),
                senderExists: { _ in true },
                delivery: .unknown
            ),
            .absent
        )
    }

    func testEveryHookPresentAndPointingSomewhereRealReadsAsInstalled() {
        let hooks = ToolingHooks.hooks(for: .claude)
        let paths = Dictionary(uniqueKeysWithValues: hooks.map { ($0, "/A/AgentWatchSend") })

        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in true }, delivery: .arrived),
            .installed
        )
    }

    /// Named, not counted: "2 of 13 missing" tells a person there is a problem and nothing
    /// about which one, and the two answers — reinstall, or accept — depend on which.
    func testMissingHooksAreNamedInTheOrderTheyAreDeclared() {
        let hooks = ToolingHooks.hooks(for: .claude)
        var paths = Dictionary(uniqueKeysWithValues: hooks.map { ($0, "/A/AgentWatchSend") })
        paths["PreCompact"] = nil
        paths["Stop"] = nil

        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in true }, delivery: .arrived),
            .incomplete(missing: ["Stop", "PreCompact"])
        )
    }

    /// Stale means the entry cannot work — the file it names is gone. Deliberately not "the
    /// path is not the one I would write now": a development build and an installed bundle
    /// both work, because the sender only delivers to a socket and no one cares which copy
    /// did it. Judging one against the other would report a working setup as broken every
    /// time a person switched between them.
    func testAnEntryNamingASenderThatIsGoneReadsAsStale() {
        let hooks = ToolingHooks.hooks(for: .claude)
        let paths = Dictionary(uniqueKeysWithValues: hooks.map { ($0, "/gone/AgentWatchSend") })

        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in false }, delivery: .arrived),
            .stale(senderPaths: ["/gone/AgentWatchSend"])
        )
    }

    /// The state the menu could not say before: everything is registered, the sender is there,
    /// and not one event has ever arrived from this agent.
    ///
    /// For Codex that is the ordinary state right after installing — it skips a hook whose
    /// definition it has not been asked to trust, so the records are in place and nothing
    /// fires. Reading that as `installed` states something the app has no evidence for, and
    /// there is nothing for a person to notice: it looks exactly like an agent nobody used
    /// today.
    func testRecordsThatHaveNeverDeliveredAnythingDoNotReadAsWorking() {
        let hooks = ToolingHooks.hooks(for: .codex)
        let paths = Dictionary(uniqueKeysWithValues: hooks.map { ($0, "/A/AgentWatchSend") })

        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in true }, delivery: .nothingSinceInstall),
            .unheard
        )
        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in true }, delivery: .arrived),
            .installed,
            "one event is all the proof needed, and it never expires"
        )
    }

    /// The third answer, and without it the other two are a trap. Records installed by an
    /// older Agent Watch, or by hand, have no history here — the app started keeping one only
    /// now. Calling that "nothing has arrived" would announce a fault on the first launch of
    /// every working setup.
    ///
    /// So the claim is deliberately narrow: it is made only about records this app installed
    /// itself and has heard nothing from since. Everything else reads as it did before.
    func testRecordsThisAppNeverInstalledAreNotAccusedOfSilence() {
        let hooks = ToolingHooks.hooks(for: .codex)
        let paths = Dictionary(uniqueKeysWithValues: hooks.map { ($0, "/A/AgentWatchSend") })

        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in true }, delivery: .unknown),
            .installed
        )
    }

    /// Incomplete comes first, because the two want opposite things from a person. Missing
    /// records are repaired by installing; records that have never delivered are not — for
    /// Codex the answer is to approve them in Codex, and writing the file again changes
    /// nothing.
    func testMissingRecordsMatterMoreThanNeverHavingHeardAnything() {
        let hooks = ToolingHooks.hooks(for: .codex)
        var paths = Dictionary(uniqueKeysWithValues: hooks.map { ($0, "/A/AgentWatchSend") })
        paths["Stop"] = nil

        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in true },
                delivery: .nothingSinceInstall),
            .incomplete(missing: ["Stop"])
        )
    }

    /// An installation made by an older Agent Watch carries an entry for an event this one no
    /// longer asks for, and that must not read as a problem: the entry is ours, it works, and
    /// the next install takes it out. Reading it as incomplete would offer a repair for
    /// something already whole; reading it as stale would call a working setup broken.
    ///
    /// It is not free — an entry we do not ask for still costs a process launch per event —
    /// so the answer is one reinstall, not a state of its own to explain.
    func testAnEntryForAnEventWeNoLongerAskForStillReadsAsInstalled() {
        let hooks = ToolingHooks.hooks(for: .claude)
        var paths = Dictionary(uniqueKeysWithValues: hooks.map { ($0, "/A/AgentWatchSend") })
        paths["PostToolUse"] = "/A/AgentWatchSend"

        XCTAssertEqual(
            ToolingInstallation.state(
                senderPaths: paths, hooks: hooks, senderExists: { _ in true }, delivery: .arrived),
            .installed
        )
    }

    /// The settings file is the one place the app writes into that belongs to someone else,
    /// and it only ever shrinks there. Hooks registered by hand before the plugin existed
    /// would otherwise fire alongside it, doubling a cost that is already the expensive part.
    func testOurOwnEntriesComeOutOfSettingsAndNothingElseMoves() {
        let theirs = JSONValue.object([
            "type": .string("command"),
            "command": .string("bash ~/.claude/hooks/git-guard.sh"),
        ])
        let settings = JSONValue.object([
            "model": .string("opus"),
            "hooks": .object([
                "PreToolUse": .array([
                    .object(["hooks": .array([Self.ourEntry(event: "PreToolUse")])]),
                    .object(["matcher": .string("Bash"), "hooks": .array([theirs])]),
                ]),
                "Stop": .array([.object(["hooks": .array([Self.ourEntry(event: "Stop")])])]),
            ]),
        ])

        XCTAssertEqual(
            ToolingInstallation.removingOurHooks(from: settings, source: .claude),
            .object([
                "model": .string("opus"),
                "hooks": .object([
                    // Their group keeps its place; ours is gone, and `Stop`, which held
                    // nothing else, goes with it rather than staying behind as an empty key.
                    "PreToolUse": .array([
                        .object(["matcher": .string("Bash"), "hooks": .array([theirs])])
                    ])
                ]),
            ])
        )
    }

    private static func ourEntry(event: String) -> JSONValue {
        .object([
            "type": .string("command"),
            "command": .string("/old/AgentWatchSend --source claude --event \(event)"),
            "timeout": .number(3),
        ])
    }

    /// Codex has no plugin mechanism, so its hooks go into its own configuration file, which
    /// may hold someone else's. Ours are merged in beside them, and a second run changes
    /// nothing — a person may press install twice, and an installer that grows the file each
    /// time would fire every hook twice, then three times.
    func testCodexHooksAreMergedInBesideWhatIsAlreadyThereAndOnlyOnce() {
        let theirs = JSONValue.object([
            "hooks": .array([.object(["type": .string("command"), "command": .string("say hello")])])
        ])
        let existing = JSONValue.object(["hooks": .object(["SessionStart": .array([theirs])])])
        let hooks = ["SessionStart"]

        let once = ToolingInstallation.addingOurHooks(
            to: existing,
            source: .codex,
            senderPath: "/A/AgentWatchSend",
            hooks: hooks
        )
        let twice = ToolingInstallation.addingOurHooks(
            to: once,
            source: .codex,
            senderPath: "/A/AgentWatchSend",
            hooks: hooks
        )

        XCTAssertEqual(
            ToolingInstallation.senderPaths(inHooks: once, source: .codex),
            ["SessionStart": "/A/AgentWatchSend"]
        )
        XCTAssertEqual(twice, once, "installing twice must leave what installing once left")
        guard case let .object(root) = once, case let .object(events)? = root["hooks"],
            case let .array(groups)? = events["SessionStart"]
        else {
            return XCTFail("the document lost its shape")
        }
        XCTAssertTrue(groups.contains(theirs), "somebody else's hook keeps its place")
    }

    /// Codex records hook trust positionally: `~/.codex/config.toml` keeps a `trusted_hash`
    /// per hook under a key of `path:event:group:hook`. So moving somebody else's entry
    /// costs them their trust just as surely as editing it would, and they then have to
    /// approve their own hook again. Measured on 0.140.
    ///
    /// Keeping ours last is what makes that impossible: a foreign group already in the file
    /// never changes index, on install or on removal. `contains` cannot see this — the
    /// existing merge test passes with ours written first.
    func testOurEntriesGoAfterSomebodyElsesSoTheirsNeverMoves() {
        let theirs = JSONValue.object([
            "hooks": .array([.object(["type": .string("command"), "command": .string("plannotate")])])
        ])
        let existing = JSONValue.object(["hooks": .object(["Stop": .array([theirs])])])
        let hooks = ["Stop"]

        let installed = ToolingInstallation.addingOurHooks(
            to: existing,
            source: .codex,
            senderPath: "/A/AgentWatchSend",
            hooks: hooks
        )

        XCTAssertEqual(Self.stopGroups(of: installed).first, theirs, "theirs must still be group 0")
        XCTAssertEqual(Self.stopGroups(of: installed).count, 2)
        XCTAssertEqual(
            ToolingInstallation.removingOurHooks(from: installed, source: .codex),
            existing,
            "and removal must put the file back exactly, index for index"
        )
    }

    private static func stopGroups(of document: JSONValue) -> [JSONValue] {
        guard case let .object(root) = document, case let .object(events)? = root["hooks"],
            case let .array(groups)? = events["Stop"]
        else {
            return []
        }
        return groups
    }

    /// Only a whole installation offers to be taken away. The other three — nothing there,
    /// required hooks missing, a sender that is gone — all want the same thing, and it is not
    /// uninstalling: a line that reports a fault and then removes what is left when pressed
    /// makes a person press twice to repair one problem.
    func testOnlyAWholeInstallationOffersToBeRemoved() {
        XCTAssertTrue(ToolingInstallationState.absent.wantsInstalling)
        XCTAssertTrue(ToolingInstallationState.incomplete(missing: ["Stop"]).wantsInstalling)
        XCTAssertTrue(ToolingInstallationState.stale(senderPaths: ["/gone"]).wantsInstalling)
        XCTAssertFalse(ToolingInstallationState.installed.wantsInstalling)
    }

    private static func expectedEntry(event: String) -> JSONValue {
        .array([
            .object([
                "hooks": .array([
                    .object([
                        "type": .string("command"),
                        // Quoted, and not because this path needs it: the sender's real home
                        // is `~/Library/Application Support/AgentWatch/`, and a shell reads an
                        // unquoted space as the end of the command's name.
                        "command": .string(
                            "'/Applications/AgentWatch.app/Contents/MacOS/AgentWatchSend'"
                                + " --source claude --event \(event)"
                        ),
                        "timeout": .number(3),
                    ])
                ])
            ])
        ])
    }
}
