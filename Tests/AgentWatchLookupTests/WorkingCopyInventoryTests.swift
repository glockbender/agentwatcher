import Foundation
import XCTest

@testable import AgentWatchLookup

extension WorktreeDiskReportTests {
    func testNestedCopySizesExcludeSharedMetadataAndOtherCopiesAndSortLargestFirst() throws {
        let project = try fixture().repository
        let nested = project.appendingPathComponent(".trees/small")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["worktree", "add", "--quiet", "-b", "inner", nested.path], in: project)
        try createFolder("build", in: nested, bytes: 600_000)
        try createFolder("dist", in: nested, bytes: 800_000)
        let other = try createFolder("elsewhere/small", in: project, bytes: 64_000)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("linked-copy"), withDestinationURL: nested)
        try Data(repeating: 32, count: 2_000_000).write(to: project.appendingPathComponent(".git/private-fixture"))

        let report = try WorktreeDiskScanner.scan(in: nested)
        XCTAssertEqual(report.worktrees.compactMap(\.branch), ["inner", "main"])
        let inner = try XCTUnwrap(report.worktrees.first)
        let outer = try XCTUnwrap(report.worktrees.last)
        XCTAssertGreaterThan(try XCTUnwrap(inner.allocatedBytes), 1_000_000)
        XCTAssertLessThan(try XCTUnwrap(outer.allocatedBytes), 250_000)
        XCTAssertGreaterThan(try XCTUnwrap(outer.allocatedBytes), 60_000)
        XCTAssertEqual(inner.folders.map { $0.folder.lastPathComponent }, ["dist", "build"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testChangesDistinguishIndexWorktreeAndUntrackedFilesWithoutChangingIndex() throws {
        let project = try fixture().repository
        let tracked = project.appendingPathComponent("tracked-file")
        try Data([1]).write(to: tracked)
        try git(["add", "tracked-file"], in: project)
        try git(
            [
                "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                "commit", "--quiet", "-m", "Fixture baseline",
            ], in: project)
        func changes() throws -> WorktreeChanges {
            try XCTUnwrap(WorktreeDiskScanner.scan(in: project).worktrees.first?.changes)
        }
        XCTAssertTrue(try changes().isClean)
        try Data([2, 3]).write(to: tracked)
        XCTAssertEqual(
            try changes(), WorktreeChanges(hasStagedChanges: false, hasTrackedEdits: true, hasUntrackedFiles: false))
        try git(["add", "tracked-file"], in: project)
        try Data([4]).write(to: project.appendingPathComponent("untracked\nfile"))
        let index = project.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        XCTAssertEqual(
            try changes(), WorktreeChanges(hasStagedChanges: true, hasTrackedEdits: false, hasUntrackedFiles: true))
        XCTAssertEqual(try Data(contentsOf: index), before)
        try git(["update-index", "--assume-unchanged", "tracked-file"], in: project)
        XCTAssertNil(try WorktreeDiskScanner.scan(in: project).worktrees.first?.changes)
    }

    func testInaccessibleFilesOutsideCacheBlockCleanupAndDoNotReportCleanStatus() throws {
        try XCTSkipIf(geteuid() == 0, "Root can enumerate a directory with permissions 000.")
        let project = try fixture().repository
        let blocked = try createFolder("hidden", in: project)
        let cache = try createFolder("target", in: project)
        try "Signature: 8a477f597d28d172789f06886806bc55".write(
            to: cache.appendingPathComponent("CACHEDIR.TAG"),
            atomically: false, encoding: .utf8)
        try "hidden/\ntarget/\n".write(
            to: project.appendingPathComponent(".git/info/exclude"), atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }

        let entry = try XCTUnwrap(WorktreeDiskScanner.scan(in: project, activeFolders: []).worktrees.first)
        XCTAssertNil(entry.allocatedBytes)
        XCTAssertNil(entry.changes)
        let measured = try XCTUnwrap(entry.folders.first)
        XCTAssertNotNil(measured.allocatedBytes)
        XCTAssertNil(measured.cleanup)
        XCTAssertTrue(try XCTUnwrap(measured.concern).contains("cache tag"))
    }

    func testStagedRemovalOfSubmoduleIsReported() throws {
        let project = try fixture().repository
        let gitlink = "160000,1111111111111111111111111111111111111111,external"
        try git(["update-index", "--add", "--cacheinfo", gitlink], in: project)
        try git(
            [
                "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                "commit", "--quiet", "-m", "Track a submodule",
            ], in: project)
        try git(["update-index", "--force-remove", "--", "external"], in: project)
        XCTAssertEqual(try WorktreeDiskScanner.scan(in: project).worktrees.first?.changes?.hasStagedChanges, true)
    }

    func testStatusCannotLaunchAConfiguredCleanFilter() throws {
        let project = try fixture().repository
        let path = project.appendingPathComponent("tracked-file")
        try Data([1]).write(to: path)
        try git(["add", "tracked-file"], in: project)
        try "tracked-file filter=fixture\n".write(
            to: project.appendingPathComponent(".gitattributes"),
            atomically: false, encoding: .utf8)
        try git(["config", "filter.fixture.clean", "touch filter-was-run; cat"], in: project)
        try git(["config", "filter.fixture.required", "true"], in: project)
        try Data([2]).write(to: path)
        let state = try XCTUnwrap(WorktreeDiskScanner.scan(in: project).worktrees.first?.changes)
        XCTAssertTrue(state.hasTrackedEdits)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("filter-was-run").path))
    }
}
