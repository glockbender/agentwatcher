import AgentWatchCore
import Foundation

/// Puts Agent Watch into the agents on this machine, and takes it back out.
///
/// Everything about *what* to write and what a configuration means lives in
/// `AgentWatchCore` and is tested without a disk. What lives here is the disk: which file,
/// where, and how to leave it in a state another program can read.
@MainActor
final class ToolingInstaller {
    private let home: URL
    private let fileManager = FileManager.default
    /// Whether this installer was pointed at a home of its own — see `supportDirectory`.
    private let ownHome: Bool

    /// - Parameter home: a home directory to work in instead of the running person's. Given
    ///   one, this installer keeps *everything* under it, its own folder included; given
    ///   none, its own folder is the app's, wherever the app keeps it.
    init(home: URL? = nil) {
        self.ownHome = home != nil
        self.home = home ?? AgentWatchPaths.homeDirectory()
    }

    /// Every folder of each agent: the defaults under this installer's home and the ones listed.
    func agentFolders(extra: [AgentSource: [String]]) -> AgentFolders {
        AgentFolders(home: home, extra: extra)
    }

    /// The folder an agent uses when nothing in its environment names another, under this
    /// installer's home. Every hook operation works on it unless it is given a folder.
    func defaultFolder(for source: AgentSource) -> URL {
        AgentFolders.defaultFolder(for: source, home: home)
    }

    // MARK: - Claude hooks, which live in a plugin of our own

    /// The folder Claude Code loads a personal plugin from: `skills/` in whichever folder it
    /// was started with — measured on Claude Code 2.1.294, a Claude started with
    /// `CLAUDE_CONFIG_DIR` loads the plugins there and none under `~/.claude`.
    private func claudePluginDirectory(in folder: URL) -> URL {
        folder
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(ClaudeHookPlugin.name, isDirectory: true)
    }

    private func claudeManifestURL(in folder: URL) -> URL {
        claudePluginDirectory(in: folder)
            .appendingPathComponent(".claude-plugin", isDirectory: true)
            .appendingPathComponent("plugin.json")
    }

    private func claudeHooksURL(in folder: URL) -> URL {
        claudePluginDirectory(in: folder)
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    // MARK: - By agent, so the caller does not have to know which

    /// The three hook operations, keyed by agent and done in one of its folders — the default
    /// one when none is named.
    ///
    /// Each is a switch over two genuinely different mechanisms — a folder we own for Claude
    /// Code, a merge into somebody else's file for Codex — and the point is that the switch
    /// happens once, here, instead of at every call site.
    /// - Parameter delivery: what is known about these records ever having run. Not readable
    ///   from any configuration, so it is handed in by whoever remembers.
    func hookState(for source: AgentSource, in folder: URL? = nil, delivery: HookDelivery) -> ToolingInstallationState {
        let folder = folder ?? defaultFolder(for: source)
        switch source {
        case .claude: return claudeHookState(in: folder, delivery: delivery)
        case .codex: return codexHookState(in: folder, delivery: delivery)
        }
    }

    func installHooks(for source: AgentSource, in folder: URL? = nil, senderPath: String, hooks: [String]) throws {
        let folder = folder ?? defaultFolder(for: source)
        switch source {
        case .claude: try installClaudeHooks(in: folder, senderPath: senderPath, hooks: hooks)
        case .codex: try installCodexHooks(in: folder, senderPath: senderPath, hooks: hooks)
        }
    }

    func removeHooks(for source: AgentSource, in folder: URL? = nil) throws {
        let folder = folder ?? defaultFolder(for: source)
        switch source {
        case .claude: try removeClaudeHooks(in: folder)
        case .codex: try removeCodexHooks(in: folder)
        }
    }

    /// Where this agent's hook file lives, for a message that has to name it. A person told
    /// only that "the configuration cannot be read" has to guess which of three files is meant.
    func hooksPath(for source: AgentSource, in folder: URL? = nil) -> URL {
        let folder = folder ?? defaultFolder(for: source)
        switch source {
        case .claude: return claudeHooksURL(in: folder)
        case .codex: return codexHooksURL(in: folder)
        }
    }

    private func claudeHookState(in folder: URL, delivery: HookDelivery) -> ToolingInstallationState {
        let document: JSONValue?
        do {
            document = try read(claudeHooksURL(in: folder))
        } catch {
            return .unreadable
        }
        guard let document else {
            return .absent
        }
        return ToolingInstallation.state(
            senderPaths: ToolingInstallation.senderPaths(inHooks: document, source: .claude),
            hooks: ToolingHooks.hooks(for: .claude),
            senderExists: { self.fileManager.fileExists(atPath: $0) },
            delivery: delivery
        )
    }

    private func installClaudeHooks(in folder: URL, senderPath: String, hooks: [String]) throws {
        // The mirror of the guard on removal, and the reason that guard needs one: writing a
        // manifest into somebody else's folder of the same name would make it look like ours,
        // and removal trusts the manifest — so the next uninstall would delete their work.
        try refuseAFolderThatIsNotOurs(in: folder)
        try write(ClaudeHookPlugin.manifest(), to: claudeManifestURL(in: folder))
        try write(ClaudeHookPlugin.hooksDocument(senderPath: senderPath, hooks: hooks), to: claudeHooksURL(in: folder))
    }

    /// Takes the plugin away, folder and all.
    ///
    /// Refuses a folder it cannot recognise as its own. This deletes a directory under a
    /// person's `~/.claude`, and a person may well have a skill of their own by this name —
    /// removing that would be destroying their work, not uninstalling ours. The manifest is
    /// the proof: it is written by the installer and names the plugin.
    private func removeClaudeHooks(in folder: URL) throws {
        let pluginDirectory = claudePluginDirectory(in: folder)
        guard fileManager.fileExists(atPath: pluginDirectory.path) else {
            return
        }
        try refuseAFolderThatIsNotOurs(in: folder)
        try fileManager.removeItem(at: pluginDirectory)
    }

    /// Throws unless the plugin folder is absent or carries our own manifest.
    ///
    /// The manifest is the proof, because the installer is the only thing that writes one.
    private func refuseAFolderThatIsNotOurs(in folder: URL) throws {
        let pluginDirectory = claudePluginDirectory(in: folder)
        guard fileManager.fileExists(atPath: pluginDirectory.path) else {
            return
        }
        guard
            let data = try? Data(contentsOf: claudeManifestURL(in: folder)),
            case let .object(manifest)? = try? JSONDecoder().decode(JSONValue.self, from: data),
            case let .string(name)? = manifest["name"],
            name == ClaudeHookPlugin.name
        else {
            throw ToolingInstallerError.notOurs(pluginDirectory)
        }
    }

    // MARK: - Codex hooks, which live in Codex's own file

    /// `hooks.json` in whichever folder Codex was started with — measured on Codex 0.153.4 and
    /// 0.161.0, a Codex started with `CODEX_HOME` reads this file there and no other.
    private func codexHooksURL(in folder: URL) -> URL {
        folder.appendingPathComponent("hooks.json")
    }

    private func codexHookState(in folder: URL, delivery: HookDelivery) -> ToolingInstallationState {
        let document: JSONValue?
        do {
            document = try read(codexHooksURL(in: folder))
        } catch {
            return .unreadable
        }
        return ToolingInstallation.state(
            senderPaths: ToolingInstallation.senderPaths(inHooks: document ?? .object([:]), source: .codex),
            hooks: ToolingHooks.hooks(for: .codex),
            senderExists: { self.fileManager.fileExists(atPath: $0) },
            delivery: delivery
        )
    }

    /// Merges our hooks into Codex's own file.
    ///
    /// Codex has no plugin mechanism, so unlike Claude this is somebody else's file that we
    /// add to rather than a folder we own. Whatever else is in it keeps its place, and the
    /// file is saved before it is changed.
    private func installCodexHooks(in folder: URL, senderPath: String, hooks: [String]) throws {
        try changeCodexHooks(in: folder) {
            ToolingInstallation.addingOurHooks(
                to: $0,
                source: .codex,
                senderPath: senderPath,
                hooks: hooks
            )
        }
    }

    private func removeCodexHooks(in folder: URL) throws {
        try changeCodexHooks(in: folder) { ToolingInstallation.removingOurHooks(from: $0, source: .codex) }
    }

    private func changeCodexHooks(in folder: URL, _ change: (JSONValue) -> JSONValue) throws {
        let url = codexHooksURL(in: folder)
        let existing = try read(url) ?? .object([:])
        let changed = change(existing)
        guard changed != existing else {
            return
        }
        try backUp(url)
        try write(changed, to: url)
    }

    // MARK: - The status line, the one slot Claude Code allows only one of

    /// Agent Watch's own folder, where the relay script and the command it wraps are kept.
    ///
    /// Asked of `AgentWatchPaths` rather than derived from `home`, because that is where the
    /// one substitution lives: a debug copy run with `AGENT_WATCH_SUPPORT_DIR` keeps the
    /// socket, the lock, the settings and the remembered sessions in that folder, and these
    /// two files belong with them. Derived from `home` when this installer was given a home
    /// of its own — then the pretence is that the whole home is elsewhere, and its
    /// Application Support with it.
    var supportDirectory: URL {
        guard !ownHome, let own = AgentWatchPaths.supportDirectory() else {
            return AgentWatchPaths.supportDirectory(
                inApplicationSupport:
                    home
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
            )
        }
        return own
    }

    private var relayURL: URL { supportDirectory.appendingPathComponent("statusline-relay.sh") }

    /// A copy of the wrapped command, in plain text beside the script.
    ///
    /// So that a person who opens the folder can see what their status line used to be
    /// without reading a shell script, and without the app running.
    private var originalCommandURL: URL { supportDirectory.appendingPathComponent("original-command.txt") }

    func statusLineState() -> StatusLineState {
        let command: String?
        do {
            command = try currentStatusLineCommand()
        } catch {
            return .unreadable
        }
        guard let command else {
            return .notSet
        }
        return command.contains(relayURL.path) ? .connected : .theirs(command: command)
    }

    /// Puts the relay in front of whatever is there, keeping it.
    func connectStatusLine(senderPath: String) throws {
        // Read before writing anything at all. The settings file is checked here rather than
        // at the write below so that a file this app cannot understand leaves no relay script
        // and no companion behind — refusing halfway is still refusing, but it litters.
        let original = try currentStatusLineCommand() ?? ""
        guard !original.contains(relayURL.path) else {
            return
        }

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Data(StatusLineRelay.script(senderPath: senderPath, originalCommand: original).utf8)
            .write(to: relayURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relayURL.path)
        // Saved first, like the two files that plainly belong to someone else. This one is in
        // a folder the app owns, which makes it look like the app's to overwrite — but what is
        // in it is a command a person wrote, and disconnecting reads this file and nothing
        // else. A stale companion from a connection that was undone by hand would otherwise be
        // replaced by an empty original, and their command would be gone from its only record.
        try backUp(originalCommandURL)
        try Data(original.utf8).write(to: originalCommandURL, options: .atomic)

        try setStatusLineCommand("bash \(ShellWord.quoted(relayURL.path))")
    }

    /// Gives the slot back exactly as it was found.
    func disconnectStatusLine() throws {
        guard case .connected = statusLineState() else {
            return
        }
        // The companion file is the only record of what the slot held, so without it there is
        // nothing to give back and the promise cannot be kept. Refusing says which file is
        // missing; the alternative — treating "cannot find it" as "there was nothing" — is
        // how the one operation meant to restore a person's status line came to remove it.
        //
        // The command is also embedded in the relay script, but reading it back from there
        // would tie undoing to that script's exact wording, and the script is generated.
        guard fileManager.fileExists(atPath: originalCommandURL.path) else {
            throw ToolingInstallerError.missingOriginalCommand(originalCommandURL)
        }
        let original = try String(contentsOf: originalCommandURL, encoding: .utf8)
        try setStatusLineCommand(original.isEmpty ? nil : original)
        try? fileManager.removeItem(at: relayURL)
        try? fileManager.removeItem(at: originalCommandURL)
    }

    private func currentStatusLineCommand() throws -> String? {
        guard
            case let .object(root)? = try readClaudeSettings(),
            case let .object(statusLine)? = root["statusLine"],
            case let .string(command)? = statusLine["command"]
        else {
            return nil
        }
        return command
    }

    private func setStatusLineCommand(_ command: String?) throws {
        guard case var .object(root) = try readClaudeSettings() ?? .object([:]) else {
            return
        }
        if let command {
            var statusLine: [String: JSONValue] = [:]
            if case let .object(existing)? = root["statusLine"] {
                statusLine = existing
            }
            statusLine["type"] = .string("command")
            statusLine["command"] = .string(command)
            root["statusLine"] = .object(statusLine)
        } else {
            root.removeValue(forKey: "statusLine")
        }
        try backUp(claudeSettingsURL)
        try write(.object(root), to: claudeSettingsURL)
    }

    // MARK: - The settings file, which this app touches for the status line and nothing else

    /// The file whose status-line slot this app can take over. Named for the window that has
    /// to say which file it would write.
    var statusLinePath: URL {
        claudeSettingsURL
    }

    /// Only the default folder's: the relay and the command it wraps are kept once, in this
    /// app's own folder, so one slot is all they can stand in for. A Claude started from a
    /// listed folder keeps its own status line.
    private var claudeSettingsURL: URL {
        defaultFolder(for: .claude).appendingPathComponent("settings.json")
    }

    private func readClaudeSettings() throws -> JSONValue? {
        try read(claudeSettingsURL)
    }

    // MARK: - The disk

    /// A configuration file, or `nil` when there is none — and a thrown error when there is
    /// one this app cannot read.
    ///
    /// Those last two used to be the same answer, and they are opposites to a writer. Nothing
    /// there means start from an empty object; unreadable means somebody's configuration is
    /// in a state we do not understand, and starting from an empty object would write that
    /// emptiness over the rest of it. One trailing comma in `settings.json` cost the model,
    /// the permissions and every MCP server it named.
    private func read(_ url: URL) throws -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ToolingInstallerError.unreadable(url)
        }
        return document
    }

    /// Saves a file the app is about to change but does not own.
    ///
    /// Timestamped rather than fixed: overwriting yesterday's copy with today's would defeat
    /// the point of keeping one.
    private func backUp(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        // Two changes inside one second share a timestamp, which a first version of this
        // discovered by failing: install and remove in the same test second collided. A
        // suffix is added until the name is free, because overwriting a backup with another
        // backup loses exactly the thing being kept.
        var destination = url.appendingPathExtension("agentwatch-backup-\(stamp)")
        var attempt = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = url.appendingPathExtension("agentwatch-backup-\(stamp)-\(attempt)")
            attempt += 1
        }
        try fileManager.copyItem(at: url, to: destination)
    }

    private func write(_ document: JSONValue, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

enum ToolingInstallerError: Error {
    /// A path Agent Watch was asked to take back but cannot prove it put there.
    case notOurs(URL)
    /// A configuration file that exists but does not parse. Never written over: what it holds
    /// cannot be read, so what a write would destroy cannot be known either.
    case unreadable(URL)
    /// The status line cannot be given back because the file holding what it was is gone.
    case missingOriginalCommand(URL)
    /// A listed folder that is not on disk. Installing would create a folder no agent reads.
    case missingFolder(URL)
}
