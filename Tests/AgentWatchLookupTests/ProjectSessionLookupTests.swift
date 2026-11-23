import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchLookup

final class ProjectSessionLookupTests: XCTestCase {
    private let thread = "0ca8d555-aa73-4569-8fd1-75453225abda"

    private func folder() throws -> URL {
        let scratch =
            ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func session(_ source: AgentSource, phase: SessionPhase = .completed) -> SessionSnapshot {
        let label = HookCaptureRedactor.label(forRawIdentifier: thread)
        return SessionSnapshot(
            id: SessionSnapshot.id(source: source, sessionLabel: label), source: source, arrivalIndex: 0,
            phase: phase, lastObservedAt: .now, agentProcessID: 357, clientKind: .desktop)
    }

    func testCodexRequiresAnActiveTranscriptAndUsesOnlyItsOwnMetadata() throws {
        let home = try folder()
        let folders = AgentFolders(home: home)
        let lookup = ProjectSessionLookup(folders: folders, transcriptFiles: .live)
        let root = TranscriptLocator.defaultRoot(for: .codex, home: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout-" + thread + ".jsonl")
        let row = session(.codex)
        func metadata(_ id: String) throws {
            let record: [String: Any] = ["type": "session_meta", "payload": ["id": id, "cwd": home.path]]
            var data = try JSONSerialization.data(withJSONObject: record)
            data.append(10)
            try data.write(to: file)
        }
        try metadata(thread)
        let namesOnly = ProjectSessionLookup(folders: folders, transcriptFiles: nil)
        let named = try XCTUnwrap(namesOnly.location(of: row))
        XCTAssertNil(named.directory)
        XCTAssertNil(namesOnly.openWorkingFolders(of: [row]))
        XCTAssertEqual(lookup.openWorkingFolders(of: [row]), [home.resolvingSymlinksInPath().standardizedFileURL])
        var child = row
        child.threadKind = .subagent
        XCTAssertFalse(ProjectSessionLookup.isCandidate(child))
        XCTAssertEqual(lookup.openWorkingFolders(of: [child]), lookup.openWorkingFolders(of: [row]))

        XCTAssertEqual(lookup.openWorkingFolders(of: [session(.codex, phase: .sessionClosed)]), [])
        XCTAssertEqual(named.link, DesktopSessionLink.codex(transcript: file, sessionLabel: row.transcriptLabel))
        XCTAssertEqual(lookup.location(of: row)?.directory?.path, home.path)
        XCTAssertEqual(
            lookup.location(of: row)?.link,
            DesktopSessionLink.codex(transcript: file, sessionLabel: row.transcriptLabel))
        XCTAssertNil(lookup.location(of: session(.codex, phase: .sessionClosed)))
        try metadata(UUID().uuidString)
        XCTAssertNil(lookup.location(of: row)?.directory)
        let archive = TranscriptLocator.codexArchivedSessions(inRoot: root)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        XCTAssertNil(lookup.location(of: row))
        XCTAssertNil(namesOnly.location(of: row))
    }

    func testAmbiguousAndSymbolicCodexTranscriptsCannotOpenAChat() throws {
        let home = try folder()
        let extra = home.appendingPathComponent("work-profile")
        let folders = AgentFolders(home: home, extra: [.codex: [extra.path]])
        let roots = TranscriptLocator.roots(for: .codex, in: folders)
        let name = "rollout-" + thread + ".jsonl"
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let original = roots[0].appendingPathComponent(name)
        let duplicate = roots[1].appendingPathComponent(name)
        try Data().write(to: original)
        try Data().write(to: duplicate)
        let lookup = ProjectSessionLookup(folders: folders, transcriptFiles: .live)
        XCTAssertNil(lookup.location(of: session(.codex)))
        try FileManager.default.moveItem(at: original, to: home.appendingPathComponent("old-file"))
        try FileManager.default.moveItem(at: duplicate, to: home.appendingPathComponent("actual-file"))
        try FileManager.default.createSymbolicLink(
            at: duplicate, withDestinationURL: home.appendingPathComponent("actual-file"))
        XCTAssertNil(lookup.location(of: session(.codex)))
    }

    func testClaudeRequiresMatchingSessionAndLiveProcess() throws {
        let folder = try folder()
        let started = Date(timeIntervalSince1970: 1_000)
        let registry = ClaudeSessionRegistry(directory: folder, startTime: { _ in started })
        let lookup = ProjectSessionLookup(
            folders: AgentFolders(home: folder), transcriptFiles: nil, registry: registry,
            workingDirectory: { _ in folder.path })
        let file = folder.appendingPathComponent("357.json")
        func record(_ id: String, seconds: Double) throws {
            let fields: [String: Any] = [
                "pid": 357, "startedAt": seconds * 1_000, "entrypoint": "claude-desktop",
                "sessionId": id, "hostSessionId": "local_example",
            ]
            try JSONSerialization.data(withJSONObject: fields).write(to: file)
        }
        let row = session(.claude)
        try record(thread, seconds: 1_000)
        XCTAssertEqual(lookup.location(of: row)?.directory?.path, folder.path)
        XCTAssertEqual(
            try XCTUnwrap(lookup.location(of: row)).link,
            try XCTUnwrap(DesktopSessionLink.claude(desktopSessionID: "local_example")))
        try record("other-session", seconds: 1_000)
        XCTAssertNil(lookup.location(of: row))
        try record(thread, seconds: 50)
        XCTAssertNil(lookup.location(of: row))
    }

    func testRepositoryIdentitySurvivesAnExternalWorktreeAndSeparatesSameNamedRoots() throws {
        let home = try folder()
        func repository(_ parent: String) throws -> URL {
            let root = home.appendingPathComponent(parent + "/project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-c", "init.templateDir=", "init", "--quiet", root.path]
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
            return root
        }
        let first = try repository("first")
        let second = try repository("second")
        let common = first.appendingPathComponent(".git")
        // Git's linked-worktree format, including the link in each direction. No branches or commits are needed.
        let admin = common.appendingPathComponent("worktrees/external")
        let copy = home.appendingPathComponent("external")
        let nested = copy.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(("gitdir: " + admin.path + "\n").utf8).write(to: copy.appendingPathComponent(".git"))
        try Data((copy.appendingPathComponent(".git").path + "\n").utf8).write(
            to: admin.appendingPathComponent("gitdir"))
        try Data("../..\n".utf8).write(to: admin.appendingPathComponent("commondir"))
        try Data("ref: refs/heads/example\n".utf8).write(to: admin.appendingPathComponent("HEAD"))
        let linked = try XCTUnwrap(GitWorkingCopy.read(in: nested))
        XCTAssertEqual(linked.commonDirectory, GitWorkingCopy.read(in: first)?.commonDirectory)
        XCTAssertEqual(linked.root.path, copy.resolvingSymlinksInPath().path)
        XCTAssertEqual(linked.projectURL.path, first.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(linked.commonDirectory, try XCTUnwrap(GitWorkingCopy.read(in: second)).commonDirectory)
        XCTAssertNil(GitWorkingCopy.read(in: home))
    }
}
