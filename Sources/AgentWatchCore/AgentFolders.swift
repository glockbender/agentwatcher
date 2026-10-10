import Foundation

/// The folders each agent keeps its configuration, hooks and history in.
///
/// Each agent has one by default, `~/.claude` and `~/.codex`, and a person who starts it with
/// `CLAUDE_CONFIG_DIR` or `CODEX_HOME` pointing elsewhere has more. An agent started that way
/// reads hooks only from its own folder (measured on Codex 0.153.4 and 0.161.0 and on Claude
/// Code 2.1.294) and writes its transcripts there (measured on Codex 0.161.0 and Claude Code
/// 2.1.294), so nothing in the default folder tells the app that the others exist. A person
/// names them; ADR-0022 says why the app does not guess.
public struct AgentFolders: Equatable, Sendable {
    public let home: URL
    private let extra: [AgentSource: [URL]]

    /// - Parameter extra: the folders a person added, by agent, as absolute paths. A path that
    ///   names the default folder or one already listed is dropped, because the same folder
    ///   twice would mean the same hooks installed twice; a relative path is dropped because
    ///   nothing says what it is relative to.
    public init(home: URL, extra: [AgentSource: [String]] = [:]) {
        self.home = home
        var kept: [AgentSource: [URL]] = [:]
        for source in AgentSource.allCases {
            var seen: Set<String> = [Self.canonicalPath(of: Self.defaultFolder(for: source, home: home))]
            kept[source] = (extra[source] ?? []).compactMap { path in
                guard path.hasPrefix("/") else {
                    return nil
                }
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                return seen.insert(Self.canonicalPath(of: folder)).inserted ? folder : nil
            }
        }
        self.extra = kept
    }

    /// The folder an agent uses when nothing in its environment names another.
    public static func defaultFolder(for source: AgentSource, home: URL) -> URL {
        switch source {
        case .claude: home.appendingPathComponent(".claude", isDirectory: true)
        case .codex: home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    /// The variable that moves an agent's folder.
    public static func variableName(for source: AgentSource) -> String {
        switch source {
        case .claude: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        }
    }

    public func defaultFolder(for source: AgentSource) -> URL {
        Self.defaultFolder(for: source, home: home)
    }

    /// The folders a person added for this agent, in the order they were added.
    public func extraFolders(for source: AgentSource) -> [URL] {
        extra[source] ?? []
    }

    /// Every folder of this agent, the default first.
    public func folders(for source: AgentSource) -> [URL] {
        [defaultFolder(for: source)] + extraFolders(for: source)
    }

    public func isDefault(_ folder: URL, for source: AgentSource) -> Bool {
        Self.canonicalPath(of: folder) == Self.canonicalPath(of: defaultFolder(for: source))
    }

    /// The folder of this agent's that a label names, or `nil` for a folder nobody listed.
    public func folder(labelled label: String, for source: AgentSource) -> URL? {
        folders(for: source).first { Self.label(of: $0) == label }
    }

    // MARK: - Naming a folder across the socket

    /// What a folder is called across the socket: a label, never a path.
    ///
    /// The sender names the folder its hook ran from this way, and the app compares the label
    /// with its own folders' — the way a session's transcript is found, and for the reason
    /// `TranscriptLocator` gives: anything on this machine can connect to the socket, and a
    /// field carrying a path would be a field telling the app which folder to open.
    public static func label(of folder: URL) -> String {
        HookCaptureRedactor.label(forRawIdentifier: canonicalPath(of: folder))
    }

    /// The one spelling of a folder both sides hash.
    ///
    /// Symbolic links are resolved because the two sides start from different spellings: the
    /// sender from the path the agent wrote its transcript under, the app from the path a
    /// person picked. Codex canonicalises `CODEX_HOME` before using it (its binary carries the
    /// error for failing to), and `/tmp` against `/private/tmp` is the everyday case of the
    /// same folder spelled twice.
    public static func canonicalPath(of folder: URL) -> String {
        folder.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The folder a transcript belongs to, read from where it lies, or `nil` for a path of
    /// neither agent's shape.
    ///
    /// Claude writes `<folder>/projects/<project>/<session>.jsonl` and Codex
    /// `<folder>/sessions/<year>/<month>/<day>/rollout-….jsonl` — measured on Claude Code
    /// 2.1.294 and Codex 0.161.0 in folders named by the variable.
    public static func folder(ofTranscriptAt path: String, source: AgentSource) -> URL? {
        let components = URL(fileURLWithPath: path).pathComponents
        let (depth, marker) =
            switch source {
            case .claude: (3, "projects")
            case .codex: (5, "sessions")
            }
        guard components.count > depth + 1, components[components.count - depth] == marker else {
            return nil
        }
        return URL(
            fileURLWithPath: NSString.path(withComponents: Array(components.dropLast(depth))),
            isDirectory: true
        )
    }

    /// The folder the agent that ran a hook was started with.
    ///
    /// The transcript's path first, because that is the agent itself saying where it writes.
    /// The variable is the fallback for a hook that names no transcript, and the default
    /// folder the fallback for an agent started without the variable.
    public static func reportingFolder(
        source: AgentSource,
        transcriptPath: String?,
        environment: [String: String],
        home: URL
    ) -> URL {
        if let transcriptPath, let folder = folder(ofTranscriptAt: transcriptPath, source: source) {
            return folder
        }
        if let variable = environment[variableName(for: source)], variable.hasPrefix("/") {
            return URL(fileURLWithPath: variable, isDirectory: true)
        }
        return defaultFolder(for: source, home: home)
    }
}
