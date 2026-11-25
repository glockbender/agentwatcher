import Foundation
import XCTest

@testable import AgentWatchLookup

final class WorktreeDiskReportTests: XCTestCase {
    func testPorcelainPreservesNewlinesAndSpacesInPathsAndLockReasons() throws {
        let raw = "/tmp/a\nfolder with space"
        let data = Data(
            ("worktree \(raw)\0HEAD abc\0branch refs/heads/feature\0locked keep\nit\0\0"
                + "worktree /tmp/bare\0bare\0\0").utf8)
        let records = try WorktreeDiskScanner.parse(data)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].path, raw)
        XCTAssertEqual(records[0].branch, "feature")
        XCTAssertTrue(records[0].locked)
        XCTAssertTrue(records[1].bare)
        XCTAssertThrowsError(try WorktreeDiskScanner.parse(Data("worktree /tmp/not-terminated".utf8)))
        XCTAssertThrowsError(try WorktreeDiskScanner.parse(Data("worktree relative\0\0".utf8)))
    }

    func testOnlySelectedRepositoryAndItsLinkedCopiesAreInspected() throws {
        let fixture = try fixture()
        let linked = fixture.root.appendingPathComponent("elsewhere/feature\nwith space")
        try FileManager.default.createDirectory(
            at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["worktree", "add", "--quiet", "-b", "feature", linked.path], in: fixture.repository)
        let other = fixture.root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try git(["init", "--quiet"], in: other)
        try createFolder(".build", in: other)
        try createFolder("target", in: linked)

        let report = try WorktreeDiskScanner.scan(in: fixture.repository)
        XCTAssertEqual(
            Set(report.worktrees.map { $0.folder.resolvingSymlinksInPath().path }),
            Set([
                fixture.repository.resolvingSymlinksInPath().path, linked.resolvingSymlinksInPath().path,
            ]))
        let entry = try XCTUnwrap(report.worktrees.first { $0.branch == "feature" })
        XCTAssertNil(entry.owner)
        XCTAssertEqual(entry.folders.map { $0.folder.lastPathComponent }, ["target"])
        XCTAssertGreaterThan(try XCTUnwrap(entry.folders.first?.allocatedBytes), 0)
        XCTAssertTrue(entry.concerns.contains { $0.contains("Session activity is unavailable") })
    }

    func testSizeReportDistinguishesTrackedIgnoredAndUntrackedFolders() throws {
        let fixture = try fixture()
        try createFolder("build", in: fixture.repository)
        try createFolder("target", in: fixture.repository)
        try createFolder("dist", in: fixture.repository)
        try "target/\n".write(
            to: fixture.repository.appendingPathComponent(".gitignore"), atomically: false, encoding: .utf8)
        try git(["add", "--", "build/data"], in: fixture.repository)
        let before = try Data(contentsOf: fixture.repository.appendingPathComponent(".git/index"))

        let report = try WorktreeDiskScanner.scan(in: fixture.repository)
        let folders = try XCTUnwrap(report.worktrees.first).folders
        XCTAssertEqual(folders.count, 3)
        XCTAssertEqual(
            folders.first { $0.folder.lastPathComponent == "build" }?.evidence, "Contains Git-tracked files.")
        XCTAssertEqual(
            folders.first { $0.folder.lastPathComponent == "target" }?.evidence, "Ignored by Git; no tracked files.")
        XCTAssertEqual(
            folders.first { $0.folder.lastPathComponent == "dist" }?.evidence, "Not ignored by Git; no tracked files.")
        XCTAssertEqual(before, try Data(contentsOf: fixture.repository.appendingPathComponent(".git/index")))
        for name in ["build", "target", "dist"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixture.repository.appendingPathComponent(name + "/data").path))
        }
    }

    func testSymlinkBuildFolderIsNotMeasuredAndNestedLinkDoesNotCountItsDestination() throws {
        let fixture = try fixture()
        let outside = try createFolder("outside", in: fixture.root, bytes: 1_000_000)
        try FileManager.default.createSymbolicLink(
            at: fixture.repository.appendingPathComponent("target"), withDestinationURL: outside)
        let build = try createFolder(".build", in: fixture.repository)
        try FileManager.default.createSymbolicLink(
            at: build.appendingPathComponent("external"), withDestinationURL: outside)

        let report = try WorktreeDiskScanner.scan(in: fixture.repository)
        let folders = try XCTUnwrap(report.worktrees.first).folders
        let link = try XCTUnwrap(folders.first { $0.folder.lastPathComponent == "target" })
        XCTAssertNil(link.allocatedBytes)
        XCTAssertTrue(link.evidence.contains("not scanned"))
        XCTAssertLessThan(
            try XCTUnwrap(folders.first { $0.folder.lastPathComponent == ".build" }?.allocatedBytes), 1_000_000)
    }

    func testRemoteHistoryUsesLocalRemoteRefsAndRecognizesAnAncestor() throws {
        let fixture = try fixture()
        func evidence() throws -> String? {
            try WorktreeDiskScanner.scan(in: fixture.repository).worktrees.first?.remoteHistory
        }
        XCTAssertTrue(try XCTUnwrap(evidence()).contains("may exist only on this machine"))
        try git(["update-ref", "refs/remotes/example/main", "HEAD"], in: fixture.repository)
        XCTAssertTrue(try XCTUnwrap(evidence()).hasPrefix("At least one"))
        try git(
            [
                "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "--quiet", "--allow-empty", "-m", "Second fixture commit",
            ],
            in: fixture.repository)
        XCTAssertTrue(try XCTUnwrap(evidence()).contains("may exist only on this machine"))
        try git(["update-ref", "refs/remotes/example/main", "HEAD"], in: fixture.repository)
        try git(["switch", "--quiet", "--detach", "HEAD^"], in: fixture.repository)
        XCTAssertTrue(try XCTUnwrap(evidence()).hasPrefix("At least one"))
    }

    func testOwnerRequiresOneRegularMarkerAndGitOperationIsExplained() throws {
        let fixture = try fixture()
        let admin = fixture.repository.appendingPathComponent(".git")
        try Data().write(to: admin.appendingPathComponent("codex-thread.json"))
        try Data().write(to: admin.appendingPathComponent("MERGE_HEAD"))
        let first = try XCTUnwrap(WorktreeDiskScanner.scan(in: fixture.repository).worktrees.first)
        XCTAssertEqual(first.owner, "Codex")
        XCTAssertEqual(first.ownerEvidence, "codex-thread.json")
        XCTAssertTrue(first.concerns.contains { $0.contains("MERGE_HEAD") })
        try Data().write(to: admin.appendingPathComponent("mothership-worktree"))
        let second = try XCTUnwrap(WorktreeDiskScanner.scan(in: fixture.repository).worktrees.first)
        XCTAssertNil(second.owner)
        XCTAssertTrue(second.concerns.contains { $0.contains("Conflicting") })
    }

    func testMissingWorktreeAndExpiredScanDoNotLookSafe() throws {
        let fixture = try fixture()
        let linked = fixture.root.appendingPathComponent("linked")
        try git(["worktree", "add", "--quiet", "-b", "feature", linked.path], in: fixture.repository)
        try FileManager.default.moveItem(at: linked, to: fixture.root.appendingPathComponent("moved-feature"))
        let report = try WorktreeDiskScanner.scan(in: fixture.repository)
        let missing = try XCTUnwrap(report.worktrees.first { $0.branch == "feature" })
        XCTAssertTrue(missing.folders.isEmpty)
        XCTAssertTrue(missing.concerns.contains { $0.contains("unavailable") })
        XCTAssertThrowsError(try WorktreeDiskScanner.scan(in: fixture.repository, timeLimit: 0))
        XCTAssertThrowsError(try WorktreeDiskScanner.scan(in: fixture.root))
    }

    func testNestedRegistrationWithoutItsGitFileDoesNotReadTheParentAsItsOwner() throws {
        let fixture = try fixture()
        let linked = fixture.repository.appendingPathComponent("nested-copy")
        try git(["worktree", "add", "--quiet", "-b", "nested", linked.path], in: fixture.repository)
        try createFolder("target", in: linked)
        try Data().write(to: fixture.repository.appendingPathComponent(".git/codex-thread.json"))
        try FileManager.default.moveItem(
            at: linked.appendingPathComponent(".git"), to: fixture.root.appendingPathComponent("saved-git-link"))

        let report = try WorktreeDiskScanner.scan(in: fixture.repository)
        let entry = try XCTUnwrap(report.worktrees.first { $0.branch == "nested" })
        XCTAssertNil(entry.owner)
        XCTAssertTrue(entry.folders.isEmpty)
        XCTAssertTrue(entry.concerns.contains { $0.contains("no longer belongs") })
    }

    func fixture() throws -> (root: URL, repository: URL) {
        let scratch = ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"]
        let parent =
            scratch.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("AgentWatch-disk-" + UUID().uuidString)
        let repository = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        if scratch == nil {
            addTeardownBlock { try FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        }
        try git(["init", "--quiet", "-b", "main"], in: repository)
        try git(
            [
                "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--allow-empty", "-m", "Fixture",
            ], in: repository)
        return (root, repository)
    }

    @discardableResult
    func createFolder(_ name: String, in parent: URL, bytes: Int = 8192) throws -> URL {
        let folder = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: folder.appendingPathComponent("data"))
        return folder
    }

    func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Fixture Git command failed: \(arguments)")
    }
}
