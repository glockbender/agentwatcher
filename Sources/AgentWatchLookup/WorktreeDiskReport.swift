import AgentWatchGit
import Darwin
import Foundation

/// A bounded, explicit inventory. A measured cache is not evidence that nobody is using it.
public struct WorktreeDiskReport: Sendable {
    public let repository: URL
    public let scannedAt: Date
    public let worktrees: [WorktreeDiskEntry]

    public var measuredBytes: Int64 {
        worktrees.flatMap(\.folders).compactMap(\.allocatedBytes).reduce(0, +)
    }
}

public struct WorktreeDiskEntry: Identifiable, Sendable {
    public var id: String { folder.path }
    public let folder: URL
    public let branch: String?
    public let owner: String?
    public let ownerEvidence: String?
    public let remoteHistory: String?
    public internal(set) var allocatedBytes: Int64?
    public internal(set) var changes: WorktreeChanges?
    public let concerns: [String]
    public let folders: [WorktreeBuildFolder]
}

public struct WorktreeChanges: Equatable, Sendable {
    public let hasStagedChanges: Bool
    public let hasTrackedEdits: Bool
    public let hasUntrackedFiles: Bool

    public var isClean: Bool { !hasStagedChanges && !hasTrackedEdits && !hasUntrackedFiles }
}

public struct WorktreeBuildFolder: Identifiable, Sendable {
    public var id: String { folder.path }
    public let folder: URL
    public let allocatedBytes: Int64?
    public let evidence: String
    public let concern: String?
    public internal(set) var cleanup: WorktreeCacheAssessment?
}

public enum WorktreeDiskScanner {
    // These are candidates to inspect, never a deletion allow-list. Projects can put source
    // files in any of them; Git tracking and ignore rules remain separate evidence.
    static let buildFolderNames = [
        ".build", "target", "node_modules", "build", "dist", ".gradle", ".next", ".cache", ".venv", "vendor",
    ]
    private static let ownerMarkers = [
        ("claude-desktop-worktree", "Claude"), ("codex-thread.json", "Codex"),
        ("mothership-worktree", "Mothership"),
    ]
    static let operationMarkers = [
        "MERGE_HEAD", "REBASE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD",
        "REVERT_HEAD", "BISECT_LOG", "BISECT_START", "sequencer", "index.lock",
    ]

    /// Follows only Git's list for the selected repository. It never searches the home folder
    /// or reads session stores or remote state. Git uses local data to check working files.
    public static func scan(in folder: URL, timeLimit: TimeInterval = 45, activeFolders: Set<URL>? = nil) throws
        -> WorktreeDiskReport
    {
        let deadline = Date().addingTimeInterval(max(0, timeLimit))
        let common = try gitPath(["rev-parse", "--path-format=absolute", "--git-common-dir"], folder, deadline)
        let list = try git(["worktree", "list", "--porcelain", "-z"], folder, deadline)
        guard list.status == 0 else { throw ScanError.repository }
        let records = try parse(list.output)
        let boundaries = measurementBoundaries(records: records, common: common)
        let entries = records.map {
            inspect($0, common: common, boundaries: boundaries, activeFolders: activeFolders, deadline: deadline)
        }.sorted {
            if $0.allocatedBytes == $1.allocatedBytes { return $0.id < $1.id }
            return ($0.allocatedBytes ?? -1) > ($1.allocatedBytes ?? -1)
        }
        return WorktreeDiskReport(repository: common, scannedAt: Date(), worktrees: entries)
    }

    static func measurementBoundaries(records: [Record], common: URL) -> Set<String> {
        var boundaries = Set(
            records.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path })
        boundaries.insert(common.path)
        return boundaries
    }

    struct Record: Equatable {
        var path: String
        var branch: String?
        var bare = false
        var locked = false
        var prunable = false
    }

    // With -z, both fields and records have NUL boundaries; newlines belong to paths.
    static func parse(_ data: Data) throws -> [Record] {
        guard data.last == 0, let text = String(data: data, encoding: .utf8) else { throw ScanError.list }
        var records: [Record] = []
        var current: Record?
        for field in text.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty {
                if let record = current { records.append(record) }
                current = nil
            } else if field.hasPrefix("worktree ") {
                guard current == nil else { throw ScanError.list }
                let path = String(field.dropFirst(9))
                guard path.hasPrefix("/"), !path.isEmpty else { throw ScanError.list }
                current = Record(path: path)
            } else {
                guard current != nil else { throw ScanError.list }
                if field.hasPrefix("branch refs/heads/") { current?.branch = String(field.dropFirst(18)) }
                if field == "bare" { current?.bare = true }
                if field == "locked" || field.hasPrefix("locked ") { current?.locked = true }
                if field == "prunable" || field.hasPrefix("prunable ") { current?.prunable = true }
            }
        }
        guard !records.isEmpty else { throw ScanError.list }
        return records
    }

    private static func inspect(
        _ record: Record, common: URL, boundaries: Set<String>, activeFolders: Set<URL>?, deadline: Date
    ) -> WorktreeDiskEntry {
        let folder = URL(fileURLWithPath: record.path)
        var concerns: [String] = []
        if record.locked { concerns.append("Git marks this working copy as locked. Leave it in place.") }
        if record.prunable {
            concerns.append("Git marks this registration as prunable; the folder may be unavailable.")
        }
        if record.bare {
            return WorktreeDiskEntry(
                folder: folder, branch: nil, owner: nil, ownerEvidence: nil, remoteHistory: nil,
                concerns: ["Bare repository: there is no working folder to inspect."], folders: [])
        }
        do {
            // A stale registration may now name another repository. Do not inspect its data.
            let actual = try gitPath(["rev-parse", "--path-format=absolute", "--git-common-dir"], folder, deadline)
            guard actual == common else { throw ScanError.changedRepository }
            let root = try gitPath(["rev-parse", "--show-toplevel"], folder, deadline)
            guard root == folder.resolvingSymlinksInPath().standardizedFileURL else {
                throw ScanError.changedRepository
            }
            let admin = try gitPath(["rev-parse", "--absolute-git-dir"], folder, deadline)
            let markers = ownerMarkers.filter { isRegularFile(admin.appendingPathComponent($0.0)) }
            let owner = markers.count == 1 ? markers.first?.1 : nil
            let evidence = markers.count == 1 ? markers.first?.0 : nil
            if markers.count > 1 { concerns.append("Conflicting owner markers; the owner is unknown.") }
            for marker in operationMarkers where exists(admin.appendingPathComponent(marker)) {
                concerns.append("Git operation or lock present: \(marker).")
            }
            if owner == "Claude" || owner == "Codex" {
                concerns.append("This app manages the working copy. Use its own controls to retire it.")
            }
            let bytes = try? measuredBytes(root, boundaries: boundaries, deadline: deadline)
            if bytes == nil { concerns.append("The whole working copy could not be measured.") }
            let changes = bytes == nil ? nil : try? workingChanges(in: root, deadline: deadline)
            if let changes {
                if !changes.isClean { concerns.append("This working copy has local changes. Keep its files in place.") }
            } else {
                concerns.append("Could not verify all working files and staged changes. Review this copy manually.")
            }
            if let activeFolders {
                if activeFolders.contains(where: {
                    let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
                    return path == root.path || path.hasPrefix(root.path + "/")
                }) {
                    concerns.append("An observed chat uses this working copy.")
                }
            } else {
                concerns.append("Session activity is unavailable. Review this working copy manually.")
            }
            let canInspectCache = concerns.isEmpty
            let folders = buildFolderNames.compactMap { name -> WorktreeBuildFolder? in
                let candidate = root.appendingPathComponent(name, isDirectory: true)
                return inspectBuildFolder(
                    candidate, in: root, common: common, boundaries: boundaries,
                    activeFolders: canInspectCache ? activeFolders : nil, deadline: deadline)
            }.sorted {
                if $0.allocatedBytes == $1.allocatedBytes { return $0.id < $1.id }
                return ($0.allocatedBytes ?? -1) > ($1.allocatedBytes ?? -1)
            }
            return WorktreeDiskEntry(
                folder: folder, branch: record.branch, owner: owner, ownerEvidence: evidence,
                remoteHistory: remoteHistory(in: folder, deadline: deadline), allocatedBytes: bytes, changes: changes,
                concerns: concerns, folders: folders)
        } catch {
            concerns.append(error.localizedDescription)
            return WorktreeDiskEntry(
                folder: folder, branch: record.branch, owner: nil, ownerEvidence: nil, remoteHistory: nil,
                concerns: concerns, folders: [])
        }
    }

    /// A locally recorded remote branch is evidence about the commit only. Its server may
    /// have changed, and modified or untracked working files are outside the commit.
    private static func remoteHistory(in folder: URL, deadline: Date) -> String {
        let arguments = ["for-each-ref", "--count=1", "--contains=HEAD", "--format=%(refname)", "refs/remotes/"]
        guard let result = try? git(arguments, folder, deadline), result.status == 0 else {
            return "Could not check this commit against locally recorded remote branches."
        }
        if result.output.isEmpty {
            return "No locally recorded remote branch contains this commit. It may exist only on this machine."
        }
        return "At least one locally recorded remote branch contains this commit."
    }

    private static func inspectBuildFolder(
        _ folder: URL, in tree: URL, common: URL, boundaries: Set<String>, activeFolders: Set<URL>?, deadline: Date
    ) -> WorktreeBuildFolder? {
        do {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
            {
                return nil
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return WorktreeBuildFolder(
                    folder: folder, allocatedBytes: nil, evidence: "Symbolic link; its destination was not scanned.",
                    concern: "This path may point outside the working copy.")
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return nil }
            var parentInfo = stat()
            guard lstat(tree.path, &parentInfo) == 0,
                let device = attributes[.systemNumber] as? NSNumber,
                device.int32Value == parentInfo.st_dev
            else {
                return WorktreeBuildFolder(
                    folder: folder, allocatedBytes: nil, evidence: "Could not verify a folder on the same filesystem.",
                    concern: "The path may be a mount point. Leave it in place.")
            }
            let tracked = try git(["ls-files", "--cached", "-z", "--", folder.lastPathComponent], tree, deadline)
            let ignored = try git(["check-ignore", "--quiet", "--", folder.lastPathComponent], tree, deadline)
            guard tracked.status == 0, ignored.status == 0 || ignored.status == 1 else { throw ScanError.metadata }
            let evidence: String
            let concern: String?
            if !tracked.output.isEmpty {
                evidence = "Contains Git-tracked files."
                concern = "This folder contains project files; its name does not make it disposable."
            } else if ignored.status == 0 {
                evidence = "Ignored by Git; no tracked files."
                concern = "Ignored files may include unique data. The name alone does not prove they can be rebuilt."
            } else {
                evidence = "Not ignored by Git; no tracked files."
                concern = "May contain uncommitted work. Inspect it before taking any action."
            }
            guard !boundaries.contains(folder.path) else {
                return WorktreeBuildFolder(
                    folder: folder, allocatedBytes: nil, evidence: evidence,
                    concern: "Git lists this folder separately. Leave it in place.")
            }
            let bytes = try measuredBytes(folder, boundaries: boundaries, deadline: deadline)
            let knownCacheOnHold =
                activeFolders == nil && tracked.output.isEmpty && ignored.status == 0
                && (try? WorktreeCacheCleanup.readCacheTag(in: folder)) != nil
            var result = WorktreeBuildFolder(
                folder: folder, allocatedBytes: bytes, evidence: evidence,
                concern: knownCacheOnHold
                    ? "The cache tag marks these files as rebuildable. Resolve the working-copy warnings above and scan again."
                    : concern)
            if let activeFolders, tracked.output.isEmpty, ignored.status == 0 {
                result.cleanup = WorktreeCacheCleanup.assess(
                    repository: common, worktree: tree, folder: folder,
                    activeFolders: activeFolders, deadline: deadline)
            }
            return result
        } catch {
            return WorktreeBuildFolder(
                folder: folder, allocatedBytes: nil, evidence: "Could not complete the check.",
                concern: error.localizedDescription)
        }
    }

    private static func exists(_ path: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path.path)) != nil
    }

    private static func isRegularFile(_ path: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }

    private static func gitPath(_ arguments: [String], _ folder: URL, _ deadline: Date) throws -> URL {
        let result = try git(arguments, folder, deadline)
        guard result.status == 0, var path = String(data: result.output, encoding: .utf8), path.last == "\n" else {
            throw ScanError.repository
        }
        path.removeLast()
        guard path.hasPrefix("/") else { throw ScanError.repository }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func git(_ arguments: [String], _ folder: URL, _ deadline: Date) throws -> GitCommand.Result {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw ScanError.timeout }
        return try GitCommand.run(arguments, in: folder, timeout: min(remaining, 10))
    }

    // The index can hide paths from ordinary status, and inspecting a submodule may execute its own
    // Git configuration. Either case leaves the completeness of the worktree status unknown.
    static func workingChanges(in tree: URL, deadline: Date) throws -> WorktreeChanges {
        let flags = try git(["ls-files", "-v", "--stage", "-z"], tree, deadline)
        guard flags.status == 0,
            flags.output.split(separator: 0).allSatisfy({
                $0.starts(with: "H ".utf8) && !$0.starts(with: "H 160000 ".utf8)
            })
        else { throw ScanError.metadata }

        let filters = try git(
            ["config", "--name-only", "--null", "--get-regexp", #"^filter\..*\.(clean|process|required)$"#], tree,
            deadline)
        guard filters.status == 0 || filters.status == 1 else { throw ScanError.metadata }
        var options = [
            "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false", "-c", "core.ignoreStat=false",
        ]
        for key in filters.output.split(separator: 0) {
            guard let name = String(data: key, encoding: .utf8) else { throw ScanError.metadata }
            options += ["-c", name + (name.hasSuffix(".required") ? "=false" : "=")]
        }
        // No renames means one NUL-delimited record per path. Only the leading ASCII status
        // bytes are interpreted, so paths may contain newlines or non-UTF8 bytes.
        let status = try git(
            options + [
                "status", "--porcelain=v1", "-z", "--no-renames",
                "--ignore-submodules=none", "--untracked-files=normal",
            ], tree, deadline)
        guard status.status == 0 else { throw ScanError.metadata }
        var staged = false
        var edited = false
        var untracked = false
        for record in status.output.split(separator: 0) {
            let xy = record.prefix(2)
            guard xy.count == 2 else { throw ScanError.metadata }
            if xy.elementsEqual("??".utf8) {
                untracked = true
            } else {
                staged = staged || xy.first != 32
                edited = edited || xy.last != 32
            }
        }
        return WorktreeChanges(hasStagedChanges: staged, hasTrackedEdits: edited, hasUntrackedFiles: untracked)
    }

    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    // Physical FTS is the walk used by BSD du. Pruning by exact path excludes a nested linked
    // copy without excluding unrelated folders that happen to share its name.
    static func measuredBytes(
        _ folder: URL, boundaries: Set<String>, deadline: Date, inspectEntry: ((stat) throws -> Void)? = nil
    ) throws -> Int64 {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(min(deadline.timeIntervalSinceNow, 10)))
        guard let path = strdup(folder.path) else { throw ScanError.size }
        defer { free(path) }
        var paths = [Optional(path), nil]
        return try paths.withUnsafeMutableBufferPointer { buffer in
            guard let walk = fts_open(buffer.baseAddress, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
                throw ScanError.size
            }
            defer { fts_close(walk) }
            var links = Set<FileID>()
            var bytes: Int64 = 0
            var rootDevice: dev_t?
            while true {
                try Task.checkCancellation()
                guard clock.now < end else { throw ScanError.timeout }
                errno = 0
                guard let node = fts_read(walk) else {
                    guard errno == 0 else { throw ScanError.size }
                    return bytes
                }
                let kind = Int32(node.pointee.fts_info)
                if kind == FTS_DP { continue }
                let nameIsGit = withUnsafePointer(to: &node.pointee.fts_name) { strcmp($0, ".git") == 0 }
                if node.pointee.fts_level > 0,
                    nameIsGit || (kind == FTS_D && boundaries.contains(String(cString: node.pointee.fts_path)))
                {
                    if kind == FTS_D, fts_set(walk, node, FTS_SKIP) != 0 { throw ScanError.size }
                    continue
                }
                guard kind != FTS_DNR, kind != FTS_ERR, kind != FTS_NS, kind != FTS_DC,
                    let info = node.pointee.fts_statp?.pointee
                else { throw ScanError.size }
                if node.pointee.fts_level == 0 {
                    guard kind == FTS_D else { throw ScanError.size }
                    rootDevice = info.st_dev
                }
                if rootDevice != info.st_dev { continue }
                try inspectEntry?(info)
                if kind != FTS_D, info.st_nlink > 1,
                    !links.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted
                {
                    continue
                }
                guard info.st_blocks >= 0, info.st_blocks <= (Int64.max - bytes) / 512 else { throw ScanError.size }
                bytes += info.st_blocks * 512
            }
        }
    }

    private enum ScanError: LocalizedError {
        case repository, changedRepository, list, metadata, size, timeout

        var errorDescription: String? {
            switch self {
            case .repository: "Could not read this Git repository. The folder may be unavailable or inaccessible."
            case .changedRepository: "This folder no longer belongs to the selected repository. It was not scanned."
            case .list: "Could not interpret Git’s working-copy list. No cleanup is available."
            case .metadata: "Could not check Git tracking and ignore rules."
            case .size: "Could not measure the whole folder. Its size is unknown."
            case .timeout: "The scan reached its time limit. Try scanning again when the disk is less busy."
            }
        }
    }
}
