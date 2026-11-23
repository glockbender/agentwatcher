import Foundation
import XCTest

@testable import AgentWatchLookup

final class WorktreeCacheCleanupTests: XCTestCase {
    private let signature = Data("Signature: 8a477f597d28d172789f06886806bc55\n# fixture\n".utf8)

    func testConfirmedTrashMovesOnlyTheMeasuredCache() throws {
        let fixture = try Fixture(tag: signature)
        let candidate = try XCTUnwrap(fixture.candidate())
        let verified = try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: [])
        var destination: NSURL?
        try FileManager.default.trashItem(at: verified, resultingItemURL: &destination)
        XCTAssertNotNil(destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.path))
        XCTAssertEqual(try String(contentsOf: fixture.source, encoding: .utf8), "fixture source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.common.path))
        XCTAssertEqual(try fixture.git(["status", "--porcelain"]), "")
    }

    func testReplacedCacheChangedDeepFileAndNewSessionAllRequireAnotherScan() throws {
        let fixture = try Fixture(tag: signature)
        let nested = fixture.cache.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let data = nested.appendingPathComponent("object")
        try Data([1]).write(to: data)
        let candidate = try XCTUnwrap(fixture.candidate())
        XCTAssertThrowsError(try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: [fixture.tree]))
        try Data([1, 2]).write(to: data)
        XCTAssertThrowsError(try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: []))
        try FileManager.default.moveItem(at: fixture.cache, to: fixture.root.appendingPathComponent("previous"))
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: false)
        try signature.write(to: fixture.tag)
        XCTAssertThrowsError(try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.tag.path))
    }

    func testTagMustBeAGenuineRegularFileAndNestedRepositoryIsProtected() throws {
        let fixture = try Fixture(tag: Data("cache".utf8))
        XCTAssertNil(fixture.candidate())
        let external = fixture.root.appendingPathComponent("other-tag")
        try signature.write(to: external)
        try FileManager.default.moveItem(at: fixture.tag, to: fixture.root.appendingPathComponent("old-tag"))
        try FileManager.default.createSymbolicLink(at: fixture.tag, withDestinationURL: external)
        XCTAssertNil(fixture.candidate())
        try FileManager.default.moveItem(at: fixture.tag, to: fixture.root.appendingPathComponent("link"))
        try signature.write(to: fixture.tag)
        try Data().write(to: fixture.cache.appendingPathComponent(".git"))
        XCTAssertNil(fixture.candidate())
    }

    func testNewLockDirtyStateAndStagedDeletionBlockTheMove() throws {
        let fixture = try Fixture(tag: signature)
        let candidate = try XCTUnwrap(fixture.candidate())
        let lock = fixture.common.appendingPathComponent("MERGE_HEAD")
        try Data().write(to: lock)
        XCTAssertThrowsError(try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: []))
        try FileManager.default.moveItem(at: lock, to: fixture.root.appendingPathComponent("old-lock"))
        try "changed".write(to: fixture.source, atomically: false, encoding: .utf8)
        XCTAssertNil(fixture.candidate())
        try fixture.git(["add", "--", "source"])
        try fixture.git(["commit", "-qm", "changed source"])
        try fixture.git(["add", "-f", "--", "target/CACHEDIR.TAG"])
        try fixture.git(["commit", "-qm", "track generated file"])
        try fixture.git(["rm", "--cached", "--", "target/CACHEDIR.TAG"])
        XCTAssertNil(fixture.candidate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.tag.path))
    }

    func testWorkingCopyWithOpenFileIsBusyEvenWhenProcessWorksElsewhere() throws {
        let fixture = try Fixture(tag: signature)
        let candidate = try XCTUnwrap(fixture.candidate())
        // The process need not open the path reported by Git. A hard link in another
        // folder has a different name but holds the very same file open.
        let alias = fixture.root.appendingPathComponent("open-alias")
        try FileManager.default.linkItem(at: fixture.source, to: alias)
        let held = try FileHandle(forReadingFrom: alias)
        defer { try? held.close() }
        let reason = fixture.assessment().reason
        XCTAssertTrue(reason.contains("running process"), reason)
        XCTAssertThrowsError(try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: []))
    }

    func testADescriptorClosingDuringTheScanIsScannedAgain() throws {
        func scan(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
        let complete = scan(["p7\0", "f3\0tREG\0D0x1000011\0i42\0"])
        let closing = scan(["p7\0", "f3\0tREG\0D0x1000011\0i42\0", "f16\0"])
        XCTAssertThrowsError(try WorktreeCacheCleanup.parseOpenFileIDs(closing, ownProcess: 7)) {
            XCTAssertTrue($0 is WorktreeCacheCleanup.IncompleteDescriptor, "\($0)")
        }

        var outputs = [closing, complete]
        let found = try WorktreeCacheCleanup.openFileIDs(attempts: 3, ownProcess: 7) { outputs.removeFirst() }
        XCTAssertEqual(found.map(\.inode), [42])
        XCTAssertTrue(outputs.isEmpty)

        var scans = 0
        XCTAssertThrowsError(
            try WorktreeCacheCleanup.openFileIDs(attempts: 3, ownProcess: 7) {
                scans += 1
                return closing
            })
        XCTAssertEqual(scans, 3, "a descriptor that stays incomplete still refuses")

        scans = 0
        XCTAssertThrowsError(
            try WorktreeCacheCleanup.openFileIDs(attempts: 3, ownProcess: 7) {
                scans += 1
                return nil
            })
        XCTAssertEqual(scans, 1, "a failed lsof is not retried")
        XCTAssertThrowsError(
            try WorktreeCacheCleanup.openFileIDs(attempts: 3, ownProcess: 8) { complete },
            "a scan that does not list this process proves nothing")
    }

    func testIncompleteTreeCannotBeCleanedEvenIfGitReportsItAsClean() throws {
        let fixture = try Fixture(tag: signature)
        let candidate = try XCTUnwrap(fixture.candidate())
        let unknown = fixture.tree.appendingPathComponent("closed")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        try Data([1]).write(to: unknown.appendingPathComponent("user-file"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unknown.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unknown.path) }
        XCTAssertThrowsError(try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.tag.path))
    }

    private final class Fixture {
        let root: URL
        let tree: URL
        var common: URL { tree.appendingPathComponent(".git", isDirectory: true) }
        var cache: URL { tree.appendingPathComponent("target", isDirectory: true) }
        var source: URL { tree.appendingPathComponent("source") }
        var tag: URL { cache.appendingPathComponent("CACHEDIR.TAG") }

        init(tag: Data) throws {
            let base =
                ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"].map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                } ?? FileManager.default.temporaryDirectory
            root = base.appendingPathComponent("CacheCleanup-" + UUID().uuidString, isDirectory: true)
            tree = root.appendingPathComponent("repository", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try git(["init", "-q", "-b", "main"])
            try "target/\n".write(to: tree.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
            try "fixture source".write(to: source, atomically: false, encoding: .utf8)
            try git(["add", ".gitignore", "source"])
            try git(["commit", "-qm", "fixture"])
            try tag.write(to: self.tag)
        }

        deinit {
            if ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"] == nil {
                try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
            }
        }

        func candidate() -> WorktreeCacheCandidate? { assessment().candidate }

        func assessment() -> WorktreeCacheAssessment {
            WorktreeCacheCleanup.assess(
                repository: common, worktree: tree, folder: cache, activeFolders: [],
                deadline: Date().addingTimeInterval(25))
        }

        @discardableResult func git(_ arguments: [String]) throws -> String {
            let task = Process()
            let output = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            task.arguments =
                [
                    "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                    "-c", "core.hooksPath=/dev/null",
                ] + arguments
            task.currentDirectoryURL = tree
            task.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            XCTAssertEqual(task.terminationStatus, 0, "Fixture Git failed: \(arguments)")
            return String(decoding: data, as: UTF8.self)
        }
    }
}
