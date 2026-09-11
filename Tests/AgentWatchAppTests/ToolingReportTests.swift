import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// The plan for the tooling manager said the set of integrations is given by data, «а не
/// разветвлениями в коде: добавление должно быть новой записью в таблице, а не новым `if` в
/// пяти местах». The menu this window replaced did not honour that at first: it named Claude
/// and Codex in source, so a third agent would have been installable and invisible.
@MainActor
final class ToolingReportTests: XCTestCase {
    func testTheWindowIsAProjectionOfTheAgentsAndTheirIntegrations() {
        let sections = report()

        XCTAssertEqual(
            agentSections(of: sections).map(\.title),
            AgentSource.allCases.map { AgentIcon.name(for: $0) },
            "one section per agent, in the order the agents are declared"
        )
        XCTAssertEqual(
            sections.flatMap { $0.rows.flatMap(\.actions) }.compactMap(\.press.integration),
            AgentSource.allCases.flatMap { source in
                ToolingIntegrations.kinds(for: source).map {
                    ToolingIntegration(source: source, kind: $0)
                }
            },
            "and one press per integration that agent has, in the order it declares them"
        )
    }

    /// Only Claude Code has a status line to take over: the slot is its own, and Codex reports
    /// context size in the transcript instead. That difference is data, and this is the line
    /// that would fail if it were ever written into the window builder again.
    func testOnlyTheAgentWithAStatusLineOffersOne() {
        XCTAssertEqual(ToolingIntegrations.kinds(for: .claude), [.hooks, .statusLine])
        XCTAssertEqual(ToolingIntegrations.kinds(for: .codex), [.hooks])
    }

    /// What the menu line could not carry, and half the reason this window exists: which
    /// file each integration writes into.
    func testEveryRowNamesTheFileItWrites() throws {
        let rows = agentSections(of: report()).flatMap(\.rows)

        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertTrue(
                row.details.contains { $0.contains("hooks.json") || $0.contains("settings.json") },
                "\(row.title) does not say which file it writes: \(row.details)"
            )
        }
    }

    /// The state a person cannot act on from here, and the one the app must not offer to fix:
    /// its only repair is a write, over a file whose contents nobody can state.
    func testAFileNobodyCanReadOffersNoPressAndSaysWhy() throws {
        let rows = report(hookState: .unreadable).flatMap(\.rows)
        let hooks = try XCTUnwrap(rows.first { $0.title == "Hooks" })

        XCTAssertTrue(hooks.actions.isEmpty)
        let nextStep = try XCTUnwrap(hooks.nextStep)
        XCTAssertTrue(nextStep.contains(".claude/hooks.json"), "and says which file to go and look at")
    }

    /// Installed and never heard from is the state a menu line could only report; the window
    /// has room to say what is left to do, and the answer differs by agent.
    func testAnInstallationThatHasDeliveredNothingSaysWhatIsLeftToDo() throws {
        let sections = report(hookState: .unheard)

        let steps = agentSections(of: sections).flatMap { $0.rows.compactMap(\.nextStep) }
        XCTAssertTrue(steps.contains { $0.contains("/reload-plugins") }, "Claude Code loads a plugin once")
        XCTAssertTrue(steps.contains { $0.contains("trust") }, "Codex fires nothing until it is told to trust")
    }

    /// Installing over a broken installation repairs it, so the press says so rather than
    /// offering to install what is already there.
    func testThePressSaysWhatItWillDoRatherThanAlwaysSayingInstall() {
        XCTAssertEqual(toolingHookActionTitle(state: .absent), "Install")
        XCTAssertEqual(toolingHookActionTitle(state: .installed), "Remove")
        XCTAssertEqual(toolingHookActionTitle(state: .unheard), "Remove")
        XCTAssertNotEqual(toolingHookActionTitle(state: .incomplete(missing: ["Stop"])), "Install")
        XCTAssertNotEqual(toolingHookActionTitle(state: .stale(senderPaths: ["/gone"])), "Install")
        XCTAssertNil(toolingHookActionTitle(state: .unreadable))
    }

    // MARK: - The IDE section

    /// The section is there whether or not anything was found: an empty list has two meanings
    /// — no IDE on this machine, or an IDE somewhere this app did not look — and only one of
    /// them is a problem.
    func testTheIDESectionSaysWhereItLookedWhenItFoundNothing() throws {
        let section = try XCTUnwrap(report().last)

        XCTAssertEqual(section.title, "IDE integrations")
        let row = try XCTUnwrap(section.rows.first { $0.title == "No JetBrains IDE found" })
        XCTAssertTrue(row.state.contains("/Applications"), "and names the folders it walked: \(row.state)")
    }

    /// The press hands a path to an IDE, so with no file to hand it cannot work — and it is
    /// off with a reason rather than gone, because a button that is not there says nothing.
    func testWithNoPluginFileTheWayInIsOffAndSaysWhy() throws {
        let rows = report(idePlugins: [reading(.neverAnswered)]).last?.rows ?? []
        let ide = try XCTUnwrap(rows.first { $0.title.hasPrefix("GoLand") })

        let page = try XCTUnwrap(ide.actions.first { $0.press == .idePluginsPage(dataDirectoryName: "GoLand2026.1") })
        XCTAssertFalse(page.isEnabled)
        XCTAssertEqual(page.hint, "No plugin file to install from yet")

        let file = try XCTUnwrap(rows.first { $0.title == "Plugin file" })
        XCTAssertTrue(try XCTUnwrap(file.nextStep).contains("release page"))
        XCTAssertTrue(file.details.contains { $0.hasSuffix("ide-plugin") }, "and always names the folder")
    }

    /// Check works only on a running IDE, so that fact is carried three ways: a dot on every
    /// IDE row, words wherever it takes something away, and the sentence at the top of the
    /// section. None of them is a colour a person has to interpret alone.
    func testEveryIDERowCarriesWhetherItIsRunning() throws {
        let rows = try XCTUnwrap(
            report(
                idePlugins: [reading(.answeredEarlier(reply)), reading(.neverAnswered, isRunning: false)],
                stagedPlugin: staged
            ).last?.rows
        )

        let ides = rows.filter { $0.title.hasPrefix("GoLand") }
        XCTAssertEqual(ides.map(\.status), [.running, .notRunning])
        XCTAssertFalse(ides[0].state.contains("unning"), "the ordinary case says it with the dot alone")
        XCTAssertTrue(ides[1].state.hasPrefix("Not running ·"), ides[1].state)

        let header = try XCTUnwrap(rows.first { $0.title == "JetBrains plugin" })
        XCTAssertTrue(header.state.contains("needs that IDE running"), header.state)
        XCTAssertNil(header.status, "and a row about the plugin itself is neither running nor not")
    }

    /// Five IDEs is an ordinary number on one machine, so anything said per row is said five
    /// times. The steps belong to the file, not to the IDE, and they are said once.
    func testTheInstallStepsAreSaidOnceRatherThanUnderEveryIDE() throws {
        let rows = try XCTUnwrap(
            report(
                idePlugins: [reading(.neverAnswered), reading(.neverAnswered, isRunning: false)],
                stagedPlugin: staged
            ).last?.rows
        )

        XCTAssertEqual(rows.filter { $0.nextStep?.contains("Install Plugin from Disk") == true }.count, 1)
        let file = try XCTUnwrap(rows.first { $0.title == "Plugin file" })
        XCTAssertTrue(try XCTUnwrap(file.nextStep).contains("Install Plugin from Disk"))
    }

    /// Opening a `jetbrains://` address at an IDE that is not running starts it. That is fine
    /// for a press that means "take me to the Plugins page" and wrong for one labelled Check,
    /// so the check is off — and says, in more than one place, what would turn it on.
    func testOnlyARunningIDECanBeAskedAQuestion() throws {
        let rows =
            report(
                idePlugins: [reading(.neverAnswered, isRunning: false)],
                stagedPlugin: staged
            ).last?.rows ?? []
        let ide = try XCTUnwrap(rows.first { $0.title.hasPrefix("GoLand") })

        let check = try XCTUnwrap(ide.actions.first { $0.press == .idePluginCheck(dataDirectoryName: "GoLand2026.1") })
        XCTAssertFalse(check.isEnabled)
        XCTAssertEqual(check.hint, "Start GoLand — only a running IDE can answer")
        XCTAssertTrue(ide.state.hasPrefix("Not running ·"), ide.state)
        XCTAssertEqual(ide.status, .notRunning)

        let page = try XCTUnwrap(ide.actions.first { $0.press == .idePluginsPage(dataDirectoryName: "GoLand2026.1") })
        XCTAssertTrue(page.isEnabled, "the way in still works: this press is what starts the IDE")
    }

    /// The distinction the whole section is built on: a file on disk says the plugin was
    /// loaded once, and only an answer to a question asked now says it is loaded.
    func testAnOldReplyIsNeverCalledInstalled() throws {
        let earlier = try XCTUnwrap(ideRow(.answeredEarlier(reply)))
        XCTAssertTrue(earlier.state.contains("earlier"), earlier.state)

        let confirmed = try XCTUnwrap(ideRow(.confirmed(reply)))
        XCTAssertTrue(confirmed.state.contains("just now"), confirmed.state)

        let silent = try XCTUnwrap(ideRow(.askedAndSilent(reply)))
        XCTAssertTrue(silent.state.contains("no answer"), silent.state)
        XCTAssertEqual(
            silent.actions.map(\.press),
            [.idePluginsPage(dataDirectoryName: "GoLand2026.1"), .idePluginCheck(dataDirectoryName: "GoLand2026.1")],
            "and offers the way back in"
        )
    }

    /// While the address is out there is nothing to press twice, and the button says so by
    /// staying where it is rather than disappearing under the hand.
    func testAnAskInFlightDisablesItsOwnButton() throws {
        let row = try XCTUnwrap(ideRow(.checking))

        let check = try XCTUnwrap(row.actions.first { $0.press == .idePluginCheck(dataDirectoryName: "GoLand2026.1") })
        XCTAssertFalse(check.isEnabled)
        XCTAssertEqual(check.hint, "Waiting for an answer")
        XCTAssertNil(row.nextStep, "nothing to do but wait")
    }

    /// An update from a file restarts the IDE whatever the plugin does — the platform decides
    /// that the moment it sees a copy already installed. Said before the press, not after.
    func testAnUpdateSaysWhatItCostsBeforeItIsPressed() throws {
        let row = try XCTUnwrap(ideRow(.confirmed(reply)))

        let nextStep = try XCTUnwrap(row.nextStep)
        XCTAssertTrue(nextStep.contains("0.1.3"), nextStep)
        XCTAssertTrue(nextStep.contains("restart"), "and says what it costs")
    }

    /// The same version on both sides is the ordinary case, and it has nothing to say.
    func testAPluginThatIsAlreadyCurrentSaysNothing() throws {
        let current = IDEPluginReply(token: "t", pluginVersion: staged?.version, ideBuild: nil, answeredAt: nil)

        XCTAssertNil(try XCTUnwrap(ideRow(.confirmed(current))).nextStep)
    }

    private var reply: IDEPluginReply {
        IDEPluginReply(token: "abcdefgh1234", pluginVersion: "0.1.2", ideBuild: "GO-261", answeredAt: nil)
    }

    private var staged: StagedIDEPlugin? {
        StagedIDEPlugin(fileName: "agent-watch-ide-0.1.3.zip", version: "0.1.3")
    }

    /// One IDE's row, with a plugin file staged — the case where every press exists.
    private func ideRow(_ presence: IDEPluginPresence) -> ToolingReportRow? {
        report(idePlugins: [reading(presence)], stagedPlugin: staged)
            .last?
            .rows
            .first { $0.title.hasPrefix("GoLand") }
    }

    private func reading(_ presence: IDEPluginPresence, isRunning: Bool = true) -> IDEPluginReading {
        IDEPluginReading(
            ide: InstalledJetBrainsIDE(
                product: JetBrainsProduct(name: "GoLand", version: "2026.1.4", dataDirectoryName: "GoLand2026.1"),
                bundlePath: "/Users/someone/Applications/GoLand.app",
                productScheme: "goland",
                isRunning: isRunning
            ),
            presence: presence
        )
    }

    private func report(
        hookState: ToolingInstallationState = .absent,
        statusLineState: StatusLineState = .notSet,
        idePlugins: [IDEPluginReading] = [],
        stagedPlugin: StagedIDEPlugin? = nil
    ) -> [ToolingReportSection] {
        ToolingReport.sections(
            hookState: { _ in hookState },
            statusLineState: { statusLineState },
            hooksPath: { "/Users/someone/.\($0.rawValue)/hooks.json" },
            statusLinePath: "/Users/someone/.claude/settings.json",
            idePlugins: idePlugins,
            stagedPlugin: stagedPlugin,
            idePluginDirectoryPath: "/Users/someone/Library/Application Support/AgentWatch/ide-plugin"
        )
    }

    /// The agents' own sections. The IDE section is not one of them and must not be: it is
    /// one plugin in somebody else's program, not an integration an agent declares.
    private func agentSections(of sections: [ToolingReportSection]) -> [ToolingReportSection] {
        Array(sections.prefix(AgentSource.allCases.count))
    }
}

extension ToolingPress {
    fileprivate var integration: ToolingIntegration? {
        guard case .integration(let integration) = self else {
            return nil
        }
        return integration
    }
}
