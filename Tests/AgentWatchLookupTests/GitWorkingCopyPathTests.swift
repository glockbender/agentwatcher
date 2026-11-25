import Foundation
import XCTest

@testable import AgentWatchLookup

final class GitWorkingCopyPathTests: XCTestCase {
    func testRepositoryPathPreservesEmbeddedAndTrailingNewlines() throws {
        let scratch =
            ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let fixture = scratch.appendingPathComponent("GitPath-" + UUID().uuidString)
        let repository = fixture.appendingPathComponent("repo\nname\n")
        let child = repository.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-c", "init.templateDir=", "init", "--quiet", repository.path]
        git.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        git.standardInput = FileHandle.nullDevice
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let result = try XCTUnwrap(GitWorkingCopy.read(in: child))
        XCTAssertEqual(result.root.path, repository.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(
            result.commonDirectory.path,
            repository.appendingPathComponent(".git").resolvingSymlinksInPath().standardizedFileURL.path)
    }
}
