import AgentWatchCore
import AgentWatchGit
import Foundation

/// Paths stay inside the app. Only Git's common directory identifies a repository across worktrees.
public struct GitWorkingCopy: Equatable, Sendable {
    public let commonDirectory: URL
    public let root: URL

    public var projectURL: URL {
        commonDirectory.lastPathComponent == ".git" ? commonDirectory.deletingLastPathComponent() : commonDirectory
    }

    public static func read(in directory: URL) -> Self? {
        guard let common = path("--git-common-dir", in: directory),
            let root = path("--show-toplevel", in: directory)
        else { return nil }
        return Self(commonDirectory: common, root: root)
    }

    private static func path(_ option: String, in directory: URL) -> URL? {
        guard let result = try? GitCommand.run(["rev-parse", "--path-format=absolute", option], in: directory),
            result.status == 0, var path = String(data: result.output, encoding: .utf8), path.last == "\n"
        else { return nil }
        // Each query returns one path. Only Git's final delimiter is removed; a newline
        // inside the folder name is part of the path, not another result.
        path.removeLast()
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }
}

/// Evidence for a currently addressable desktop chat. A completed turn still has a chat;
/// a closed session, archived transcript or stale process record cannot supply one.
public struct ProjectSessionLocation: Equatable, Sendable {
    public let link: URL
    public let directory: URL?

    public init(link: URL, directory: URL?) {
        self.link = link
        self.directory = directory
    }
}

public struct ProjectSessionLookup: Sendable {
    private let folders: AgentFolders
    private let registry: ClaudeSessionRegistry
    private let transcriptFiles: TitleFileSystem?
    private let workingDirectory: @Sendable (Int32) -> String?

    public init(
        folders: AgentFolders, transcriptFiles: TitleFileSystem?, registry: ClaudeSessionRegistry? = nil,
        workingDirectory: @escaping @Sendable (Int32) -> String? = AgentProcessLocator.workingDirectoryPath(of:)
    ) {
        self.folders = folders
        self.transcriptFiles = transcriptFiles
        self.registry = registry ?? ClaudeSessionRegistry(directories: ClaudeSessionRegistry.directories(in: folders))
        self.workingDirectory = workingDirectory
    }

    public static func isCandidate(_ session: SessionSnapshot) -> Bool {
        session.hostKind == .desktop && session.phase != .sessionClosed && session.phase != .terminalClosed
            && session.threadKind != .subagent && session.threadKind != .review
    }

    /// A missing location must keep the cleanup decision open. In desktop clients many
    /// chats share one process, so its current directory cannot stand in for a chat's folder.
    public func openWorkingFolders(of snapshots: [SessionSnapshot]) -> Set<URL>? {
        let open = snapshots.filter { $0.phase != .sessionClosed && $0.phase != .terminalClosed }
        guard !open.isEmpty else { return [] }
        let desktop = open.filter { $0.hostKind == .desktop }
        let directories = desktop.isEmpty ? [:] : desktopLocations(of: desktop)
        var folders: Set<URL> = []
        for session in open {
            if session.hostKind == .desktop {
                guard let directory = directories[session.id]?.directory else { return nil }
                folders.insert(directory.resolvingSymlinksInPath().standardizedFileURL)
            } else {
                // Any session that runs in its own agent process has that process's folder:
                // a terminal, a background session, `claude -p` or an IDE alike. Only a
                // session with no live process of its own leaves the answer unknown.
                guard let pid = session.agentProcessID, pid > 1,
                    let birth = AgentProcessLocator.startTime(of: pid), birth <= session.lastObservedAt,
                    let path = workingDirectory(pid), let directory = Self.absoluteDirectory(path),
                    AgentProcessLocator.startTime(of: pid) == birth
                else { return nil }
                folders.insert(directory.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        return folders
    }

    public func location(of session: SessionSnapshot) -> ProjectSessionLocation? {
        locations(of: [session])[session.id]
    }

    public func locations(of snapshots: [SessionSnapshot]) -> [String: ProjectSessionLocation] {
        desktopLocations(of: snapshots.filter(Self.isCandidate))
    }

    private func desktopLocations(of candidates: [SessionSnapshot]) -> [String: ProjectSessionLocation] {
        let labels = Set(candidates.filter { $0.source == .codex }.map(\.transcriptLabel))
        let files = TranscriptLocator.uniqueMatches(
            sessionLabels: labels, source: .codex, roots: TranscriptLocator.roots(for: .codex, in: folders))
        var found: [String: ProjectSessionLocation] = [:]
        for session in candidates {
            guard !Task.isCancelled else { break }
            found[session.id] = location(of: session, codexFile: files[session.transcriptLabel])
        }
        return found
    }

    private func location(of session: SessionSnapshot, codexFile: URL?) -> ProjectSessionLocation? {
        switch session.source {
        case .claude:
            guard let pid = session.agentProcessID, let record = registry.record(ofLiveProcess: pid),
                let link = DesktopSessionLink.claude(record: record, sessionLabel: session.transcriptLabel)
            else { return nil }
            let directory = workingDirectory(pid).flatMap(Self.absoluteDirectory)
            guard registry.record(ofLiveProcess: pid) == record else { return nil }
            return ProjectSessionLocation(link: link, directory: directory)
        case .codex:
            guard let file = codexFile, Self.isRegularTranscript(file),
                let link = DesktopSessionLink.codex(transcript: file, sessionLabel: session.transcriptLabel)
            else { return nil }
            // The link and archive check need only a file name. With transcript reading off,
            // the app has no source for this chat's working folder.
            guard let transcriptFiles, !Task.isCancelled else {
                return ProjectSessionLocation(link: link, directory: nil)
            }
            let head = transcriptFiles.readHead(file.path, SessionDescriptionResolver.codexSessionMetaByteCount)
            let directory = head.flatMap { Self.codexDirectory(in: $0, sessionLabel: session.transcriptLabel) }
            return ProjectSessionLocation(link: link, directory: directory)
        }
    }

    static func isRegularTranscript(_ file: URL) -> Bool {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink == false
    }

    private static func codexDirectory(in head: Data, sessionLabel: String) -> URL? {
        guard let end = head.firstIndex(of: 10),
            let record = try? JSONSerialization.jsonObject(with: head.prefix(upTo: end)) as? [String: Any],
            record["type"] as? String == "session_meta", let meta = record["payload"] as? [String: Any],
            let id = meta["id"] as? String, HookCaptureRedactor.label(forRawIdentifier: id) == sessionLabel,
            let path = meta["cwd"] as? String
        else { return nil }
        return absoluteDirectory(path)
    }

    private static func absoluteDirectory(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
