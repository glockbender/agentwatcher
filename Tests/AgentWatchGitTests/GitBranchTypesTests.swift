import Foundation
import XCTest

@testable import AgentWatchGit

final class GitBranchTypesTests: XCTestCase {
    /// The fixtures the Rust tests read too, so the two sides cannot drift apart.
    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("native/git-protection/tests/fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    private func scratch() throws -> URL {
        let parent =
            ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = parent.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        return url
    }

    private struct PatternCase: Decodable {
        let pattern: String
        let name: String
        let matches: Bool
    }

    func testPatternsFollowTheFixtureTheRustSideReads() throws {
        let cases = try JSONDecoder().decode([PatternCase].self, from: fixture("branch-patterns.json"))
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            XCTAssertEqual(
                GitBranchTypes.matches(pattern: item.pattern, name: item.name), item.matches,
                "\(item.pattern) vs \(item.name)")
        }
    }

    func testTheAppWritesTheTableTheRustSideReads() throws {
        let table = GitBranchTypes(types: [
            GitBranchType(name: "Features", patterns: ["feature/*", "fix/*"], level: .click),
            GitBranchType(name: "Releases", patterns: ["release/*", "hotfix/*"], level: .name),
            GitBranchType(name: "Agent drafts", patterns: ["agent/*", "tmp/*"], level: .none),
            GitBranchType(name: "Archive", patterns: ["archive/*"], level: .forbid),
        ])
        let url = try scratch().appendingPathComponent("AgentWatch/\(GitBranchTypes.fileName)")
        try table.save(to: url)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: fixture("branch-types.json")) as? NSDictionary
        XCTAssertEqual(written, expected)
        XCTAssertEqual(try GitBranchTypes.load(from: url), table)
    }

    func testTheFirstMatchingTypeWins() {
        let table = GitBranchTypes(types: [
            GitBranchType(name: "Drafts", patterns: ["agent/*"], level: .none),
            GitBranchType(name: "Everything", patterns: ["*"], level: .forbid),
            GitBranchType(name: "Late", patterns: ["agent/x"], level: .name),
        ])
        XCTAssertEqual(table.matching("agent/x")?.name, "Drafts")
        XCTAssertEqual(table.matching("feature/y")?.name, "Everything")
        XCTAssertNil(GitBranchTypes().matching("feature/y"))
    }

    func testLevelsAreOrderedWeakestFirst() {
        XCTAssertEqual(GitCheckLevel.allCases.sorted(), [.none, .click, .name, .forbid])
        XCTAssertEqual(max(GitCheckLevel.none, .name), .name)
    }

    func testAMissingFileIsAnEmptyTableAndABrokenOneIsAnError() throws {
        let folder = try scratch()
        let missing = folder.appendingPathComponent(GitBranchTypes.fileName)
        XCTAssertEqual(try GitBranchTypes.load(from: missing), GitBranchTypes())
        try Data("{".utf8).write(to: missing)
        XCTAssertThrowsError(try GitBranchTypes.load(from: missing))
        try Data(#"{"version":2,"types":[]}"#.utf8).write(to: missing)
        XCTAssertThrowsError(try GitBranchTypes.load(from: missing)) { error in
            XCTAssertEqual(error as? GitBranchTypes.TableError, .unknownVersion(2))
        }
    }

    func testThePreviewAppliesTheFloorToTheType() {
        let table = GitBranchTypes(types: [
            GitBranchType(name: "Drafts", patterns: ["agent/*", "main"], level: .none),
            GitBranchType(name: "Locked", patterns: ["locked/*"], level: .forbid),
        ])
        XCTAssertEqual(GitDeletionPreview.builtIn.deletionLevel(in: table, branch: "main").level, .name)
        XCTAssertEqual(GitDeletionPreview.projectRule.deletionLevel(in: table, branch: "agent/x").level, .name)
        XCTAssertEqual(GitDeletionPreview.includedRule.deletionLevel(in: table, branch: "agent/x").level, .name)
        let draft = GitDeletionPreview.dependsOnRemote.deletionLevel(in: table, branch: "agent/x")
        XCTAssertEqual(draft.level, .none)
        XCTAssertEqual(draft.type, "Drafts")
        XCTAssertEqual(GitDeletionPreview.builtIn.deletionLevel(in: table, branch: "locked/x").level, .forbid)
        let plain = GitDeletionPreview.dependsOnRemote.deletionLevel(in: table, branch: "feature/x")
        XCTAssertEqual(plain.level, .click)
        XCTAssertNil(plain.type)
    }
}
