import AgentWatchCore

/// One integration, as the tooling window describes it.
struct ToolingReportRow: Equatable {
    let title: String
    /// Whether the thing this row is about is running, when that is a question at all.
    ///
    /// Only IDE rows have it: what an IDE can be asked depends on it, and a disabled button
    /// is not an explanation. `nil` for every row where nothing is running or not running.
    let status: ToolingRowStatus?
    /// Where this integration stands, in one sentence.
    let state: String
    /// What is on disk: the file this app writes into, or the bundle it read. A path and
    /// nothing else — this is the half of the answer the menu had no room for, and the half a
    /// person needs before they trust an app that edits somebody else's configuration.
    let details: [String]
    /// What is left for the person to do, when anything is.
    let nextStep: String?
    /// The presses this row offers, in the order they would be used.
    let actions: [ToolingReportAction]
}

/// Whether an IDE is open right now.
enum ToolingRowStatus: Equatable {
    case running
    case notRunning
}

struct ToolingReportAction: Equatable {
    let title: String
    let press: ToolingPress
    /// Off when the press cannot do its work — no plugin file, an IDE that is not running, an
    /// answer still on its way. The button stays in place rather than vanishing: a button
    /// that is not there says nothing, and a row that loses one moves under the hand.
    let isEnabled: Bool
    /// Why it is off, shown on hover. A disabled `NSButton` does show it — checked on a live
    /// window, because AppKit is not consistent about disabled controls and a tooltip nobody
    /// sees is worse than none.
    ///
    /// Never the only place a reason is given for something a person has to act on: a pointer
    /// resting on a button is not how anybody discovers anything.
    let hint: String?

    init(title: String, press: ToolingPress, isEnabled: Bool = true, hint: String? = nil) {
        self.title = title
        self.press = press
        self.isEnabled = isEnabled
        self.hint = hint
    }
}

/// What a button in this window does.
///
/// An agent's integration is a pair — which agent, which of its integrations — and the IDE
/// plugin is neither: the IDE installs it, and all Agent Watch can do is open a page or ask a
/// question. Naming both kinds in one type is what lets one window hold both without the
/// agent rows learning anything about IDEs.
enum ToolingPress: Hashable {
    case integration(ToolingIntegration)
    /// Copy the plugin file's path and open this IDE's Plugins page.
    case idePluginsPage(dataDirectoryName: String)
    /// Ask this IDE whether the plugin is loaded in it, now.
    case idePluginCheck(dataDirectoryName: String)
}

struct ToolingReportSection: Equatable {
    let title: String
    let rows: [ToolingReportRow]
}

/// One IDE and where its plugin stands, read in one go.
struct IDEPluginReading: Equatable {
    let ide: InstalledJetBrainsIDE
    let presence: IDEPluginPresence
}

/// The tooling window as data, so that what it says can be tested without opening a window.
///
/// A projection of the agents and the integrations each of them declares, walked rather than
/// named: a third agent has to be a new entry in `ToolingIntegrations`, never a new branch
/// here. That property is the one the menu this replaced was written to keep, and it is kept.
@MainActor
enum ToolingReport {
    /// - Parameters:
    ///   - hookState: read per agent, from disk, because the files belong to other programs.
    ///   - statusLineState: read once — the slot is Claude Code's and there is only one.
    ///   - hooksPath: where this app writes that agent's hooks.
    ///   - statusLinePath: the file whose status-line slot is being talked about.
    ///   - idePlugins: every JetBrains IDE found on this machine, and what is known about the
    ///     plugin in each. Empty is an ordinary answer and has its own row.
    ///   - stagedPlugin: the plugin file waiting to be installed, when there is one.
    ///   - idePluginDirectoryPath: where that file is looked for, said whether or not one is
    ///     there — it is the one place a person can put one.
    static func sections(
        hookState: (AgentSource) -> ToolingInstallationState,
        statusLineState: () -> StatusLineState,
        hooksPath: (AgentSource) -> String,
        statusLinePath: String,
        idePlugins: [IDEPluginReading],
        stagedPlugin: StagedIDEPlugin?,
        idePluginDirectoryPath: String
    ) -> [ToolingReportSection] {
        let agents = AgentSource.allCases.map { source in
            ToolingReportSection(
                title: AgentIcon.name(for: source),
                rows: ToolingIntegrations.kinds(for: source).map { kind in
                    switch kind {
                    case .hooks:
                        hooksRow(source: source, state: hookState(source), path: hooksPath(source))
                    case .statusLine:
                        statusLineRow(source: source, state: statusLineState(), path: statusLinePath)
                    }
                }
            )
        }
        return agents + [
            ideSection(
                readings: idePlugins,
                stagedPlugin: stagedPlugin,
                directoryPath: idePluginDirectoryPath
            )
        ]
    }

    private static func hooksRow(
        source: AgentSource,
        state: ToolingInstallationState,
        path: String
    ) -> ToolingReportRow {
        let hooks = ToolingHooks.hooks(for: source)
        return ToolingReportRow(
            title: "Hooks",
            status: nil,
            state: toolingHookStateText(state: state, hooks: hooks),
            details: ["Writes \(path)"],
            nextStep: toolingHookNextStep(state: state, source: source, path: path),
            actions: toolingHookActionTitle(state: state).map {
                [
                    ToolingReportAction(
                        title: $0,
                        press: .integration(ToolingIntegration(source: source, kind: .hooks))
                    )
                ]
            } ?? []
        )
    }

    private static func statusLineRow(
        source: AgentSource,
        state: StatusLineState,
        path: String
    ) -> ToolingReportRow {
        ToolingReportRow(
            title: "Status line",
            status: nil,
            state: statusLineStateText(state: state),
            details: ["Writes \(path)"],
            nextStep: statusLineNextStep(state: state),
            actions: statusLineActionTitle(state: state).map {
                [
                    ToolingReportAction(
                        title: $0,
                        press: .integration(ToolingIntegration(source: source, kind: .statusLine))
                    )
                ]
            } ?? []
        )
    }

    /// The IDE half of the window: one plugin, every IDE it could be in, and the two ways it
    /// gets there.
    ///
    /// A section rather than a screen of its own, and that is a decision: the person does the
    /// installing inside somebody else's program, and everything this app can do is say where
    /// each IDE stands and open the right page. Marketplace is what will make even that
    /// unnecessary — see `docs/implementation-plan.md`.
    private static func ideSection(
        readings: [IDEPluginReading],
        stagedPlugin: StagedIDEPlugin?,
        directoryPath: String
    ) -> ToolingReportSection {
        var rows = [
            ToolingReportRow(
                title: "JetBrains plugin",
                status: nil,
                state: idePluginPurpose,
                details: [],
                nextStep: nil,
                actions: []
            )
        ]
        if readings.isEmpty {
            rows.append(
                ToolingReportRow(
                    title: "No JetBrains IDE found",
                    status: nil,
                    state: noJetBrainsIDEText,
                    details: [],
                    nextStep: nil,
                    actions: []
                )
            )
        } else {
            rows.append(contentsOf: readings.map { ideRow($0, stagedPlugin: stagedPlugin) })
        }
        rows.append(
            ToolingReportRow(
                title: "Marketplace",
                status: nil,
                state: idePluginMarketplaceText,
                details: [],
                nextStep: nil,
                actions: []
            )
        )
        rows.append(
            ToolingReportRow(
                title: "Plugin file",
                status: nil,
                state: idePluginFileText(staged: stagedPlugin),
                details: [directoryPath],
                nextStep: idePluginFileNextStep(staged: stagedPlugin),
                actions: []
            )
        )
        return ToolingReportSection(title: "IDE integrations", rows: rows)
    }

    /// Both presses on every IDE, and neither of them hidden.
    ///
    /// A press that cannot work is off and says why on hover, rather than being left out: a
    /// missing button is indistinguishable from a feature that does not exist, and with five
    /// IDEs on a machine the column would be a different shape on every row.
    ///
    /// `Check` needs a running IDE, and that is not a nicety: the address it opens would
    /// start an IDE that is not running, and starting somebody's IDE because they opened a
    /// settings window is not something a press labelled "Check" may do.
    private static func ideRow(_ reading: IDEPluginReading, stagedPlugin: StagedIDEPlugin?) -> ToolingReportRow {
        let ide = reading.ide
        let addressable = ide.productScheme != nil
        let actions = [
            ToolingReportAction(
                title: idePluginPageActionTitle,
                press: .idePluginsPage(dataDirectoryName: ide.product.dataDirectoryName),
                isEnabled: addressable && stagedPlugin != nil,
                hint: idePluginPageHint(ide: ide, staged: stagedPlugin)
            ),
            ToolingReportAction(
                title: "Check",
                press: .idePluginCheck(dataDirectoryName: ide.product.dataDirectoryName),
                isEnabled: addressable && ide.isRunning && reading.presence != .checking,
                hint: idePluginCheckHint(presence: reading.presence, ide: ide)
            ),
        ]
        return ToolingReportRow(
            title: ide.name,
            status: ide.isRunning ? .running : .notRunning,
            state: idePluginStateText(presence: reading.presence, isRunning: ide.isRunning),
            details: [ide.bundlePath] + idePluginReplyDetails(presence: reading.presence),
            nextStep: idePluginNextStep(presence: reading.presence, staged: stagedPlugin),
            actions: actions
        )
    }
}
