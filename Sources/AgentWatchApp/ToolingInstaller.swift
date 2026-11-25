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
    /// Use an explicit home when installing into an isolated configuration.
    init(home: URL? = nil) {
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
        try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try AgentProfileLock(folder)
        defer { withExtendedLifetime(lock) {} }
        let url = codexHooksURL(in: folder)
        let existing = try read(url) ?? .object([:])
        let changed = change(existing)
        guard changed != existing else {
            return
        }
        try backUp(url)
        try write(changed, to: url)
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
    /// A listed folder that is not on disk. Installing would create a folder no agent reads.
    case missingFolder(URL)
}
