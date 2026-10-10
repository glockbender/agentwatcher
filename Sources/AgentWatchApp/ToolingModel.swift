import AgentWatchCore
import AppKit

/// What the Tooling page shows and where its guide stands.
///
/// Held by `SettingsModel` rather than by the page, because the settings window lets go of its
/// pages when it closes: a guide followed beside a terminal must still be on its step when the
/// window is opened again. Every press goes out through `act`, so what the page can write is
/// tested here without drawing it.
@MainActor
final class ToolingModel: ObservableObject {
    /// Read from disk on every visit and after every press, because these files belong to
    /// other programs and other people: a state cached here would describe the last time this
    /// app looked rather than what is there now.
    private let facts: () -> ToolingFacts
    private let act: (ToolingPress) -> Void
    private let forgetLastError: () -> Void

    @Published private(set) var reading = ToolingFacts.unavailable
    @Published private(set) var journey: SetupJourney?

    init(
        facts: @escaping () -> ToolingFacts,
        act: @escaping (ToolingPress) -> Void,
        forgetLastError: @escaping () -> Void = {}
    ) {
        self.facts = facts
        self.act = act
        self.forgetLastError = forgetLastError
    }

    /// The page came on screen. A failure belongs to the attempt that produced it, so a new
    /// visit starts without it; the rows already say what is wrong now.
    ///
    /// With nothing connected at all, the visit starts the guide: the overview of an empty
    /// installation is a list of `Install` buttons with nothing to say which comes first.
    func pageOpened() {
        forgetLastError()
        let fresh = facts()
        if journey == nil && AgentSource.allCases.allSatisfy({ fresh.hookState($0) == .absent }) {
            journey = SetupJourney()
        }
        show(fresh)
    }

    /// Reads the disk again. Whoever performs a press says when the facts changed, and the page
    /// is redrawn from that one reading: every row can change when any one is pressed —
    /// installing points the sender link at this build, which is a line in every other row.
    func reread() {
        show(facts())
    }

    /// Called on delivery, never by an idle timer. Only an agent's first event changes this page.
    func receivedEvents(_ sources: Set<AgentSource>) {
        guard sources != reading.receivedSources else { return }
        reread()
    }

    var sections: [ToolingReportSection] {
        ToolingReport.sections(
            hookState: reading.hookState,
            statusLineState: { reading.statusLineState },
            hooksPath: reading.hooksPath,
            folders: { reading.folders[$0] ?? [] },
            statusLinePath: reading.statusLinePath,
            idePlugins: reading.idePlugins,
            stagedPlugin: reading.stagedPlugin,
            idePluginDirectoryPath: reading.idePluginDirectoryPath
        )
    }

    /// A button on one of the overview's rows.
    func press(_ press: ToolingPress) {
        act(press)
    }

    // MARK: - The guide

    /// Starts the guide over. Nothing is read: the page in front of the person was drawn from
    /// a reading that every press and every first event keeps current.
    func startSetup() {
        journey = SetupJourney()
    }

    func choose(_ source: AgentSource) {
        journey?.choose(source)
    }

    func back() {
        journey?.back()
    }

    /// Leaves the guide for the overview. Nothing is written: the guide's own presses are the
    /// only ones that write, and each was a press of its own.
    func finishSetup() {
        journey = nil
    }

    /// Installs the chosen agent's hooks. Install only: a guide drawn before somebody changed
    /// the configuration elsewhere must never be able to take a connection away.
    func connect() {
        guard let source = journey?.source else { return }
        act(.install(ToolingIntegration(source: source, kind: .hooks)))
    }

    func connectStatusLine() {
        act(.install(ToolingIntegration(source: .claude, kind: .statusLine)))
    }

    /// The hooks are written, so trying the agent can tell something.
    var canContinue: Bool {
        guard let source = journey?.source else { return false }
        let state = reading.hookState(source)
        return state == .installed || state == .unheard
    }

    /// On to trying the agent — and straight past it when the agent has already been heard
    /// from, which the reading in hand can say without another look at the disk.
    func continueToVerification() {
        guard let source = journey?.source else { return }
        journey?.continueToVerification(hooks: reading.hookState(source))
        observeJourney()
    }

    private func show(_ fresh: ToolingFacts) {
        reading = fresh
        observeJourney()
    }

    private func observeJourney() {
        guard let source = journey?.source else { return }
        journey?.observe(hooks: reading.hookState(source), receivedEvent: reading.receivedSources.contains(source))
    }
}

/// One reading of everything the Tooling page shows.
///
/// Taken in one go and handed over as a value, so every row on the page describes the same
/// moment. Reading each answer where it is needed let a window show a state from before a
/// press beside one from after it.
@MainActor
struct ToolingFacts {
    let hookState: (AgentSource) -> ToolingInstallationState
    let statusLineState: StatusLineState
    let hooksPath: (AgentSource) -> String
    let statusLinePath: String
    let senderPath: String
    /// The link could not be made, so the entries name this build's own binary. See
    /// `SenderLink`.
    let senderIsTiedToThisBuild: Bool
    /// Every JetBrains IDE on this machine and what is known about the plugin in each, found
    /// again on every visit: an IDE updated since the last one keeps its settings in a
    /// different directory, so a remembered answer would describe a plugin the new version
    /// never loaded.
    let idePlugins: [IDEPluginReading]
    let stagedPlugin: StagedIDEPlugin?
    let idePluginDirectoryPath: String
    var agentPaths: [AgentSource: String] = [:]
    /// Every folder of each agent, the default first, and where its hooks stand there.
    var folders: [AgentSource: [ToolingFolderReading]] = [:]
    var receivedSources: Set<AgentSource> = []
    var lastError: String?
    /// The widget's combination as the menu prints it, only while it is registered and so
    /// really works; `nil` otherwise. Filled in by the application, which holds the shortcut.
    var widgetShortcut: String?

    /// What the page shows before its first reading, and when the application that answers
    /// these questions has gone. Nothing is claimed and nothing is offered: an empty answer
    /// beats a stale one, and a button here would write files on behalf of an app that is no
    /// longer there.
    static let unavailable = ToolingFacts(
        hookState: { _ in .unreadable },
        statusLineState: .unreadable,
        hooksPath: { _ in "" },
        statusLinePath: "",
        senderPath: "",
        senderIsTiedToThisBuild: false,
        idePlugins: [],
        stagedPlugin: nil,
        idePluginDirectoryPath: ""
    )
}

func agentInstallationText(_ path: String?) -> String {
    path == nil ? "○ Not found in common locations · you can still connect it" : "✓ Installed on this Mac"
}

/// How the guide says the widget is shown and hidden. The combination only while it works: a
/// guide that printed a dead one would promise what the menu, for the same reason, will not.
func setupWidgetToggleText(shortcut: String?) -> String {
    guard let shortcut else {
        return "Show Widget in the menu bar brings the widget back. A shortcut can be set in Settings → General."
    }
    return "\(shortcut) shows or hides the widget (you can change it in Settings → General)."
}

func setupConnectionText(_ state: ToolingInstallationState) -> String {
    switch state {
    case .installed: "✓ Connection installed"
    case .unheard: "◑ Connection installed · waiting for the first event"
    case .absent: "○ Not connected yet"
    case .incomplete, .stale: "! Connection needs repair"
    case .unreadable: "! Configuration cannot be read"
    }
}
