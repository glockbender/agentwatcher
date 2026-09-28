import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchLookup

final class AgentInstallationLookupTests: XCTestCase {
    func testExecutableInPathIsFoundWithoutRunningIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for source in AgentSource.allCases {
            let file = root.appendingPathComponent(source.rawValue)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            XCTAssertEqual(
                AgentInstallationLookup.executable(for: source, home: root, searchPath: root.path, applications: []),
                file.path)
        }
    }

    /// Launched from Finder, the app sees none of the directories a shell adds to `PATH`, so
    /// the places installers and Node version managers use are looked at by name.
    func testTheHomeDirectoryPlacesAreFoundWithoutPath() throws {
        let layouts: [(AgentSource, String)] = [
            (.claude, ".claude/local/claude"),
            (.claude, ".volta/bin/claude"),
            (.codex, ".bun/bin/codex"),
            (.codex, ".nvm/versions/node/v22.11.0/bin/codex"),
        ]
        for (source, relative) in layouts {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)

            XCTAssertEqual(
                AgentInstallationLookup.executable(for: source, home: root, searchPath: "", applications: []),
                file.path,
                relative
            )
        }
    }

    func testDirectoryAndNonExecutableFileAreNotInstallationEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("codex")
        try Data().write(to: file)
        XCTAssertNotEqual(
            AgentInstallationLookup.executable(for: .claude, home: root, searchPath: root.path, applications: []),
            root.appendingPathComponent("claude").path)
        XCTAssertNotEqual(
            AgentInstallationLookup.executable(for: .codex, home: root, searchPath: root.path, applications: []),
            file.path)
    }
}
