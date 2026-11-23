import AgentWatchGit
import CryptoKit
import Darwin
import Foundation

public struct WorktreeCacheAssessment: Sendable {
    public let reason: String
    public let candidate: WorktreeCacheCandidate?
}

public struct WorktreeCacheCandidate: Sendable, Equatable {
    fileprivate let repository: URL
    fileprivate let worktree: URL
    public let folder: URL
    fileprivate let treeID: CacheFileID
    fileprivate let repositoryID: CacheFileID
    fileprivate let folderID: CacheFileID
    fileprivate let fingerprint: Data
}

private struct CacheFileID: Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanos: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanos = info.st_birthtimespec.tv_nsec
    }
}

/// Eligibility is specific to the measured cache. It never authorizes retiring its working copy.
public enum WorktreeCacheCleanup {
    private struct Refusal: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    public static func assess(
        repository: URL, worktree: URL, folder: URL, activeFolders: Set<URL>, deadline: Date
    ) -> WorktreeCacheAssessment {
        do {
            let candidate = try inspect(
                repository: repository, worktree: worktree, folder: folder, activeFolders: activeFolders,
                deadline: deadline)
            return WorktreeCacheAssessment(
                reason:
                    "The cache tag identifies rebuildable data. Git has no files here, the working copy is clean, and no use by your processes or monitored sessions was found.",
                candidate: candidate)
        } catch {
            return WorktreeCacheAssessment(reason: error.localizedDescription, candidate: nil)
        }
    }

    /// A volume-relative object path keeps Foundation from trashing a replacement with the same name.
    /// The caller passes this URL directly to trashItem, immediately after the person's confirmation.
    public static func verifiedTrashURL(_ candidate: WorktreeCacheCandidate, activeFolders: Set<URL>) throws -> URL {
        let current = try inspect(
            repository: candidate.repository, worktree: candidate.worktree, folder: candidate.folder,
            activeFolders: activeFolders, deadline: Date().addingTimeInterval(30))
        guard current == candidate else {
            throw Refusal("The folder or its contents changed since the scan. Scan again before moving it.")
        }
        let id = current.folderID
        let object = URL(fileURLWithPath: "/.vol/\(id.device)/\(id.inode)", isDirectory: true)
        guard CacheFileID(try info(object)) == id, CacheFileID(try info(current.folder)) == id else {
            throw Refusal("Could not identify the same folder on its volume.")
        }
        return object
    }

    private static func inspect(
        repository: URL, worktree: URL, folder: URL, activeFolders: Set<URL>, deadline: Date
    ) throws -> WorktreeCacheCandidate {
        let tree = worktree.resolvingSymlinksInPath().standardizedFileURL
        let common = repository.resolvingSymlinksInPath().standardizedFileURL
        let name = folder.lastPathComponent
        guard WorktreeDiskScanner.buildFolderNames.contains(name),
            samePath(folder.deletingLastPathComponent(), tree)
        else { throw Refusal("Only a build folder directly inside this working copy can be moved.") }
        let cache = tree.appendingPathComponent(name, isDirectory: true)
        let cacheInfo = try info(cache)
        let treeInfo = try info(tree)
        guard cacheInfo.st_mode & S_IFMT == S_IFDIR, cacheInfo.st_dev == treeInfo.st_dev else {
            throw Refusal("This path is a link, mount point, or inaccessible folder.")
        }
        try readCacheTag(in: cache)
        if activeFolders.contains(where: { contains(tree, $0.resolvingSymlinksInPath().standardizedFileURL) }) {
            throw Refusal("A monitored session is using this working copy.")
        }
        func git(_ args: [String]) throws -> GitCommand.Result {
            try GitCommand.run(args, in: tree, timeout: min(10, try remaining(deadline)))
        }
        func gitPath(_ args: [String]) throws -> URL {
            let result = try git(args)
            guard result.status == 0, var path = String(data: result.output, encoding: .utf8),
                path.first == "/", path.last == "\n"
            else { throw Refusal("Could not verify this working copy with Git.") }
            path.removeLast()
            return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        }
        guard try samePath(gitPath(["rev-parse", "--show-toplevel"]), tree),
            try samePath(gitPath(["rev-parse", "--path-format=absolute", "--git-common-dir"]), common)
        else { throw Refusal("This working copy no longer belongs to the selected repository.") }
        let treeID = CacheFileID(treeInfo)
        let commonID = CacheFileID(try info(common))
        let list = try git(["worktree", "list", "--porcelain", "-z"])
        guard list.status == 0 else { throw Refusal("Could not verify registered working copies.") }
        let records = try WorktreeDiskScanner.parse(list.output)
        guard let registration = records.first(where: { samePath(URL(fileURLWithPath: $0.path), tree) }),
            !registration.locked, !registration.prunable, !registration.bare
        else { throw Refusal("Git marks this working copy as locked, missing, or unavailable.") }
        if records.contains(where: { contains(cache, URL(fileURLWithPath: $0.path).standardizedFileURL) }) {
            throw Refusal("A linked working copy is registered inside this folder.")
        }
        let openFiles = try openFileIDs(deadline: deadline)
        let boundaries = WorktreeDiskScanner.measurementBoundaries(records: records, common: common)
        _ = try WorktreeDiskScanner.measuredBytes(tree, boundaries: boundaries, deadline: deadline) { item in
            if openFiles.contains(OpenFileID(device: item.st_dev, inode: item.st_ino)) {
                throw Refusal("A running process has a file or its working directory open in this working copy.")
            }
        }
        let admin = try gitPath(["rev-parse", "--absolute-git-dir"])
        for marker in ["claude-desktop-worktree", "codex-thread.json"]
        where try exists(admin.appendingPathComponent(marker)) {
            throw Refusal("An agent manages this working copy. Use its own controls to clean it.")
        }
        for marker in WorktreeDiskScanner.operationMarkers where try exists(admin.appendingPathComponent(marker)) {
            throw Refusal("Git has an unfinished operation or lock here (\(marker)).")
        }
        let index = try git(["ls-files", "--cached", "-z", "--", name])
        let head = try git(["ls-tree", "-z", "HEAD", "--", name])
        let ignored = try git(["check-ignore", "--quiet", "--", name])
        guard index.status == 0, head.status == 0, ignored.status == 0 else {
            throw Refusal("Could not verify that Git ignores this folder.")
        }
        guard index.output.isEmpty, head.output.isEmpty else {
            throw Refusal("The index or current commit contains files in this folder.")
        }
        guard try WorktreeDiskScanner.workingChanges(in: tree, deadline: deadline).isClean else {
            throw Refusal(
                "The working copy has uncommitted changes. Keep the cache until those changes are accounted for.")
        }
        let fingerprint = try contentsFingerprint(cache, device: cacheInfo.st_dev, deadline: deadline)
        guard CacheFileID(try info(cache)) == CacheFileID(cacheInfo), CacheFileID(try info(tree)) == treeID,
            CacheFileID(try info(common)) == commonID
        else { throw Refusal("The working copy changed during inspection.") }
        return WorktreeCacheCandidate(
            repository: common, worktree: tree, folder: cache, treeID: treeID, repositoryID: commonID,
            folderID: CacheFileID(cacheInfo), fingerprint: fingerprint)
    }

    static func readCacheTag(in folder: URL) throws {
        let tag = folder.appendingPathComponent("CACHEDIR.TAG")
        let fd = open(tag.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw Refusal("No readable cache tag. This folder may contain files that cannot be rebuilt.")
        }
        defer { close(fd) }
        var meta = stat()
        let signature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)
        var header = [UInt8](repeating: 0, count: signature.count)
        guard fstat(fd, &meta) == 0, meta.st_mode & S_IFMT == S_IFREG,
            read(fd, &header, header.count) == signature.count, header == signature
        else { throw Refusal("This folder has no valid cache tag declaring its contents rebuildable.") }
    }

    private static func contentsFingerprint(_ folder: URL, device: dev_t, deadline: Date) throws -> Data {
        if try exists(folder.appendingPathComponent("HEAD")), try exists(folder.appendingPathComponent("objects")) {
            throw Refusal("This folder may itself be a bare Git repository.")
        }
        var complete = true
        let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [], options: [],
            errorHandler: { _, _ in
                complete = false
                return false
            })
        guard let enumerator else { throw Refusal("The cache contents could not be checked.") }
        var fingerprint = SHA256()
        for case let url as URL in enumerator {
            _ = try remaining(deadline)
            let item = try info(url)
            guard item.st_dev == device else { throw Refusal("This folder contains another mounted volume.") }
            guard url.lastPathComponent.lowercased() != ".git" else {
                throw Refusal("This folder contains a nested Git repository or working copy.")
            }
            let type = item.st_mode & S_IFMT
            if type == S_IFDIR {
                if try exists(url.appendingPathComponent("HEAD")), try exists(url.appendingPathComponent("objects")) {
                    throw Refusal("This folder contains a possible bare Git repository.")
                }
            } else if type != S_IFREG && type != S_IFLNK {
                throw Refusal("This folder contains a socket, device, or another special file.")
            }
            fingerprint.update(data: Data(url.path.utf8))
            fingerprint.update(
                data: Data(
                    "\0\(item.st_ino):\(item.st_mode):\(item.st_size):\(item.st_ctimespec.tv_sec):\(item.st_ctimespec.tv_nsec)\0"
                        .utf8))
        }
        guard complete else { throw Refusal("Some cache contents were inaccessible. Leave the folder in place.") }
        return Data(fingerprint.finalize())
    }

    private struct OpenFileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    // lsof prints only numeric identities and object types. Comparing identities also
    // catches a file held open through a hard link or an alternate mount path.
    private static func openFileIDs(deadline: Date) throws -> Set<OpenFileID> {
        let result = try BoundedCommand.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-n", "-P", "-w", "-a", "-u", String(getuid()), "-F0pftDi"],
            in: URL(fileURLWithPath: "/", isDirectory: true), timeout: min(8, try remaining(deadline)),
            outputLimit: 24 * 1024 * 1024)
        let failure = Refusal("Could not verify open files for your account.")
        guard result.status == 0, result.output.last == 10 else { throw failure }
        let ownProcess = "p\(getpid())"
        var sawSelf = false
        var objects = Set<OpenFileID>()
        for line in String(decoding: result.output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\0")
            guard let first = fields.first else { throw failure }
            if first.first == "p" {
                if first == ownProcess { sawSelf = true }
                continue
            }
            guard first.first == "f", let type = fields.first(where: { $0.first == "t" }) else { throw failure }
            if type == "tunknown" || type == "t?" { throw failure }
            guard type == "tREG" || type == "tDIR" else { continue }
            guard let dev = fields.first(where: { $0.hasPrefix("D0x") }),
                let value = UInt32(dev.dropFirst(3), radix: 16),
                let node = fields.first(where: { $0.first == "i" }), let inode = ino_t(node.dropFirst())
            else {
                throw failure
            }
            objects.insert(OpenFileID(device: dev_t(bitPattern: value), inode: inode))
        }
        guard sawSelf, !objects.isEmpty else { throw failure }
        return objects
    }

    private static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let root = folded(parent.path)
        let item = folded(child.path)
        return item == root || item.hasPrefix(root + "/")
    }

    private static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func info(_ url: URL) throws -> stat {
        var item = stat()
        guard lstat(url.path, &item) == 0 else { throw Refusal("Could not inspect this folder or one of its entries.") }
        return item
    }

    private static func exists(_ url: URL) throws -> Bool {
        var item = stat()
        if lstat(url.path, &item) == 0 { return true }
        if errno == ENOENT { return false }
        throw Refusal("Could not check a Git marker or directory entry.")
    }

    private static func remaining(_ deadline: Date) throws -> TimeInterval {
        try Task.checkCancellation()
        let time = deadline.timeIntervalSinceNow
        guard time > 0 else { throw Refusal("The inspection timed out. Scan again before cleaning.") }
        return time
    }
}
