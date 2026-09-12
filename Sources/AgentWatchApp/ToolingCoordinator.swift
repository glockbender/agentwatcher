import AgentWatchCore
import AgentWatchSender
import AppKit

/// Everything about attaching Agent Watch to the agents it watches: an agent's records, the
/// status line, the link the two are pointed at, and the plugin a JetBrains IDE loads.
///
/// Gathered out of `AppDelegate`, which now only puts the menu in front of it. The reason is
/// the one `SessionSupervisor` gives: that class cannot be built in a test, and a change that
/// writes into other programs' files deserves one.
///
/// What it never does is draw anything. A change tells `onChange`, and whoever is drawing
/// reads `complaint()` again — the widget's line and the installation it describes cannot
/// then disagree.
@MainActor
final class ToolingCoordinator {
    private let installer: ToolingInstaller
    private let heard: AgentHeardStore
    /// What this sitting has asked of each IDE, by its settings directory name. Never read
    /// from disk and never remembered past a launch: it is the difference between "the file
    /// says the plugin was here" and "it answered me a moment ago".
    private var ideChecks: [String: IDEPluginCheck] = [:]
    /// Eight seconds, in quarter-second looks. The reply has been seen arriving in under one;
    /// the rest of the budget is for an IDE that is busy indexing when it is asked.
    private static let idePluginReplyAttempts = 32

    /// Said out loud, for the debug window.
    var onLog: (String) -> Void = { _ in }
    /// Something about the installation changed, and whatever shows it must look again.
    var onChange: () -> Void = {}

    init(installer: ToolingInstaller = ToolingInstaller(), heard: AgentHeardStore) {
        self.installer = installer
        self.heard = heard
    }

    /// Everything the tooling window shows, read in one go. See `ToolingWindowFacts`.
    var facts: ToolingWindowFacts {
        let sender = senderLink()
        let staged = IDEPluginFiles.staged()
        return ToolingWindowFacts(
            hookState: hookState(for:),
            statusLineState: installer.statusLineState(),
            hooksPath: { [installer] in installer.hooksPath(for: $0).path },
            statusLinePath: installer.statusLinePath.path,
            senderPath: sender.path,
            senderIsTiedToThisBuild: { if case .tiedToThisBuild = sender { true } else { false } }(),
            idePlugins: idePluginReadings(),
            stagedPlugin: staged?.plugin,
            idePluginDirectoryPath: IDEPluginFiles.pluginDirectory()?.path ?? ""
        )
    }

    /// What the widget says instead of "No active sessions" when nothing can report to it,
    /// or `nil` when something can.
    func complaint() -> String? {
        toolingComplaint(states: AgentSource.allCases.map(hookState(for:)))
    }

    /// How far Agent Watch got into one agent, including the half no configuration can state:
    /// whether anything has ever arrived from it.
    func hookState(for source: AgentSource) -> ToolingInstallationState {
        installer.hookState(for: source, delivery: heard.delivery(for: source))
    }

    func press(_ press: ToolingPress) {
        switch press {
        case .integration(let integration): toggleIntegration(integration)
        case .idePluginsPage(let dataDirectoryName): openIDEPluginsPage(dataDirectoryName: dataDirectoryName)
        case .idePluginCheck(let dataDirectoryName): checkIDEPlugin(dataDirectoryName: dataDirectoryName)
        }
    }

    /// Points the stable link at this build's sender and answers with the path another
    /// program should be given. Called at launch as well as at install time, so the link
    /// names a file that exists: whichever copy is running is the one that just claimed it.
    @discardableResult
    func refreshSenderLink() -> String {
        let sender = senderLink()
        if case let .tiedToThisBuild(path) = sender {
            // Said out loud for the same reason a refused event is: the fallback works today
            // and stops working when this build goes away, and it would be written into
            // another program's configuration with nothing anywhere to explain it later.
            onLog("Stable sender link unavailable — registering this build directly: \(path)")
        }
        return sender.path
    }

    /// Every JetBrains IDE on this machine and where the plugin stands in each.
    ///
    /// Found again on every reading rather than kept: an IDE updated between two openings of
    /// the window keeps its settings in a different directory, so a remembered answer would
    /// describe a plugin the new version never loaded.
    private func idePluginReadings() -> [IDEPluginReading] {
        let isDaemonInstalled = JetBrainsInstallation.isDaemonInstalled()
        return JetBrainsIDEs.installed().map { ide in
            IDEPluginReading(
                ide: ide,
                presence: IDEPluginInstallation.presence(
                    productScheme: ide.productScheme,
                    isDaemonInstalled: isDaemonInstalled,
                    reply: IDEPluginFiles.reply(forDataDirectoryName: ide.product.dataDirectoryName),
                    check: ideChecks[ide.product.dataDirectoryName] ?? .notAsked
                )
            )
        }
    }

    private func openIDEPluginsPage(dataDirectoryName: String) {
        guard
            let ide = installedIDE(dataDirectoryName: dataDirectoryName),
            let productScheme = ide.productScheme,
            let staged = IDEPluginFiles.staged(),
            let url = IDEPluginInstallation.pluginsPageURL(productScheme: productScheme)
        else {
            onLog("Nothing to install into \(dataDirectoryName): no plugin file, or no address for that IDE")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(staged.path, forType: .string)
        _ = NSWorkspace.shared.open(url)
        onLog("\(staged.plugin.fileName) copied — opened the Plugins page in \(ide.product.name)")
    }

    /// Asks one IDE whether the plugin is loaded in it, now.
    ///
    /// The only honest answer to that question: a directory on disk proves a file was copied,
    /// not that this IDE read it. So the token goes out in an address and the plugin writes it
    /// back into a file this app owns, and nothing but that file arriving says yes.
    private func checkIDEPlugin(dataDirectoryName: String) {
        guard
            let ide = installedIDE(dataDirectoryName: dataDirectoryName),
            let productScheme = ide.productScheme
        else {
            return
        }
        let token = IDEPluginInstallation.newToken()
        guard let url = IDEPluginInstallation.pingURL(productScheme: productScheme, token: token) else {
            return
        }
        ideChecks[dataDirectoryName] = .waiting(token: token)
        // The window shows the wait as it starts; the answer, when it comes, is another change.
        onChange()
        _ = NSWorkspace.shared.open(url)
        Task { [weak self] in
            await self?.awaitIDEPluginReply(dataDirectoryName: dataDirectoryName, token: token)
        }
    }

    /// Waits for the reply, and stops waiting.
    ///
    /// Polling rather than watching the directory, because the wait is bounded and short and a
    /// file-system watch for a file that usually appears in under a second is machinery with
    /// nothing to do the rest of the time. Whoever shows the answer is told either way: an
    /// answer that never came is the result the section exists to show.
    private func awaitIDEPluginReply(dataDirectoryName: String, token: String) async {
        for _ in 0..<Self.idePluginReplyAttempts {
            try? await Task.sleep(for: .milliseconds(250))
            if IDEPluginFiles.reply(forDataDirectoryName: dataDirectoryName)?.token == token {
                break
            }
        }
        ideChecks[dataDirectoryName] = .done(token: token)
        onChange()
    }

    private func installedIDE(dataDirectoryName: String) -> InstalledJetBrainsIDE? {
        JetBrainsIDEs.installed().first { $0.product.dataDirectoryName == dataDirectoryName }
    }

    private func toggleIntegration(_ integration: ToolingIntegration) {
        switch integration.kind {
        case .hooks: toggleHooks(for: integration.source)
        case .statusLine: toggleStatusLine()
        }
    }

    private func toggleHooks(for source: AgentSource) {
        perform {
            let state = hookState(for: source)
            guard state != .unreadable else {
                throw ToolingInstallerError.unreadable(installer.hooksPath(for: source))
            }
            if state.wantsInstalling {
                try installer.installHooks(
                    for: source,
                    senderPath: refreshSenderLink(),
                    hooks: ToolingHooks.hooks(for: source)
                )
                // After the write, so a failed install claims nothing. From here silence from
                // this agent is a fact about records this app put there, which is the only
                // silence it is entitled to report.
                heard.recordInstall(source)
                onLog(hooksInstalledMessage(for: source))
            } else {
                try installer.removeHooks(for: source)
                heard.forgetInstall(source)
                onLog("\(AgentIcon.name(for: source)) hooks removed")
            }
        }
    }

    private func toggleStatusLine() {
        perform {
            if case .connected = installer.statusLineState() {
                try installer.disconnectStatusLine()
                onLog("Status line disconnected — your own command is back")
            } else {
                try installer.connectStatusLine(senderPath: refreshSenderLink())
                onLog("Status line connected — your own command still runs")
            }
        }
    }

    /// The same question as `refreshSenderLink` without the announcement, for the window that
    /// shows the answer rather than acting on it. A line in the debug log every time a window
    /// is redrawn would bury the one that means something: a link that could not be made
    /// while installing.
    private func senderLink() -> SenderPath {
        // From the bundle rather than from `argv[0]`: this decides what ends up in another
        // program's configuration, and what a launcher put in `argv[0]` is up to the launcher.
        let executable =
            Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        // `current` and not `refresh`: this is the reporting path. The link is claimed at
        // launch and by `refreshSenderLink()`, and a window that describes what was written
        // must not be one of the things that writes it.
        return SenderLink().current(forExecutableAt: executable.resolvingSymlinksInPath())
    }

    /// Runs one tooling change, and says so either way.
    ///
    /// Failures are announced rather than thrown away: this writes into other programs'
    /// files, and a change that silently did nothing is the one outcome a person cannot
    /// diagnose.
    private func perform(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            onLog("Tooling change failed: \(error)")
        }
        // After both outcomes. A change that failed still changes what the widget should say —
        // a refused write leaves a fault standing — and refreshing only on success left the
        // empty state describing the setup as it was before the attempt.
        onChange()
    }
}
