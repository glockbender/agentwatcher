import Foundation
import XCTest

@testable import AgentWatchGit

final class GitDeletionPreviewTests: XCTestCase {
    private func folder() throws -> URL {
        let scratch = ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"]
        let parent = scratch.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let url = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        if scratch == nil {
            addTeardownBlock { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        }
        return url
    }

    private func repository() throws -> URL {
        let url = try folder()
        // A pre-commit hook exports its repository context to the test runner.
        let result = try GitCommand.run(["init", "--quiet", "--template="], in: url)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent(".git/HEAD").path))
        return url
    }

    func testBuiltInAndUnlistedBranchesWithoutAnyRemote() throws {
        let repo = try repository()
        for branch in ["main", "master"] {
            XCTAssertEqual(try GitDeletionPreview.read(in: repo, branch: branch), .builtIn)
        }
        XCTAssertEqual(try GitDeletionPreview.read(in: repo, branch: "release"), .dependsOnRemote)
    }

    func testIncludedProjectRulesMatchExactNamesFromASubdirectory() throws {
        let repo = try repository()
        let git = repo.appendingPathComponent(".git")
        let config = git.appendingPathComponent("config")
        let original = try String(contentsOf: config, encoding: .utf8)
        try (original + "\n[include]\n\tpath = rules\n").write(to: config, atomically: false, encoding: .utf8)
        try "[mothership]\nprotectedBranch = stable\nprotectedBranch = release\n".write(
            to: git.appendingPathComponent("rules"), atomically: false, encoding: .utf8)
        let child = repo.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        XCTAssertEqual(try GitDeletionPreview.read(in: child, branch: "release"), .includedRule)
        XCTAssertEqual(
            try GitDeletionPreview.setProjectRule(in: child, branch: "release", protected: false), .includedRule)
        let withInclude = try String(contentsOf: config, encoding: .utf8)
        try (withInclude + "\n[mothership]\nprotectedBranch = release\n").write(
            to: config, atomically: false, encoding: .utf8)
        XCTAssertEqual(try GitDeletionPreview.read(in: child, branch: "release"), .projectRule)
        XCTAssertEqual(
            try GitDeletionPreview.setProjectRule(in: child, branch: "release", protected: false), .includedRule)
        XCTAssertEqual(try GitDeletionPreview.read(in: child, branch: "Release"), .dependsOnRemote)
        XCTAssertEqual(try GitDeletionPreview.read(in: child, branch: "release/next"), .dependsOnRemote)
    }

    func testEditingOneRulePreservesOtherBranchesAndIsSafeToRepeat() throws {
        let repo = try repository()
        for name in ["release", "release.next", "release", "Release", "-experimental"] {
            XCTAssertEqual(try GitDeletionPreview.setProjectRule(in: repo, branch: name, protected: true), .projectRule)
        }
        for _ in 0..<2 {
            XCTAssertEqual(
                try GitDeletionPreview.setProjectRule(in: repo, branch: "release", protected: false),
                .dependsOnRemote)
        }
        for name in ["release.next", "Release", "-experimental"] {
            XCTAssertEqual(try GitDeletionPreview.read(in: repo, branch: name), .projectRule)
        }
        XCTAssertEqual(try GitDeletionPreview.setProjectRule(in: repo, branch: "main", protected: false), .builtIn)
    }

    func testInvalidInputAndUnreadableRulesDoNotProduceAPreview() throws {
        let repo = try repository()
        for name in ["", "bad..name", "release\u{0}extra", "release\u{0085}next"] {
            XCTAssertThrowsError(try GitDeletionPreview.read(in: repo, branch: name))
        }
        XCTAssertThrowsError(try GitDeletionPreview.read(in: repo.appendingPathComponent(".git"), branch: "main"))
        let other = try folder()
        XCTAssertThrowsError(try GitDeletionPreview.read(in: other, branch: "main"))
        try "[unfinished".write(to: repo.appendingPathComponent(".git/config"), atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try GitDeletionPreview.read(in: repo, branch: "release"))
    }
}
