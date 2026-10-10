import Foundation
import XCTest

@testable import AgentWatchCore

/// The file names here are copied from real directories. The whole mechanism rests on the
/// claim that an agent names a transcript after the session's own identifier, so a test that
/// invented the names would be checking nothing but itself.
final class TranscriptLocatorTests: XCTestCase {
    private let claudeSession = "bfe119e1-b5de-45e1-9035-d58c671803d0"
    private let codexSession = "01a06e14-cea8-78d0-ade0-c95e44fd5e83"

    func testFindsAClaudeTranscriptByTheLabelTheAppKnows() throws {
        let root = try makeRoot(named: [
            "-Users-someone-project-a/\(claudeSession).jsonl",
            "-Users-someone-project-b/8e341560-0990-4ff5-89d9-02ad3ae9e315.jsonl",
        ])

        let found = TranscriptLocator.locate(
            sessionLabel: HookCaptureRedactor.label(forRawIdentifier: claudeSession),
            source: .claude,
            root: root
        )

        XCTAssertEqual(found?.lastPathComponent, "\(claudeSession).jsonl")
    }

    /// Codex puts a timestamp in front of the identifier, and that timestamp contains dashes
    /// of its own — which is why the identifier is matched by shape and not by counting them.
    func testFindsACodexRolloutDespiteTheTimestampInTheName() throws {
        let root = try makeRoot(named: [
            "2026/09/04/rollout-2026-09-04T23-20-52-\(codexSession).jsonl",
            "2026/09/04/rollout-2026-09-04T23-25-11-01a06ebb-4159-7fe2-a0c9-af0ca9ae7c73.jsonl",
        ])

        let found = TranscriptLocator.locate(
            sessionLabel: HookCaptureRedactor.label(forRawIdentifier: codexSession),
            source: .codex,
            root: root
        )

        XCTAssertEqual(found?.lastPathComponent, "rollout-2026-09-04T23-20-52-\(codexSession).jsonl")
    }

    /// A subagent writes its own file beside the session's. It is not a session transcript and
    /// its name is not a session identifier, so nothing should ever match it.
    func testASubagentTranscriptIsNotASession() throws {
        let root = try makeRoot(named: ["-Users-someone-project-a/agent-a5f2ef847a12e5cd.jsonl"])

        XCTAssertNil(TranscriptLocator.sessionIdentifier(inFileNamed: "agent-a5f2ef847a12e5cd", source: .claude))
        XCTAssertNil(
            TranscriptLocator.locate(
                sessionLabel: HookCaptureRedactor.label(forRawIdentifier: "agent-a5f2ef847a12e5cd"),
                source: .claude,
                root: root
            )
        )
    }

    /// The price of looking instead of being told. A renamed transcript or a moved root finds
    /// nothing — which the caller reports as a fault, rather than showing stale work as live.
    func testNothingMatchingIsNotSilentlyTheWrongFile() throws {
        let root = try makeRoot(named: ["-Users-someone-project-a/\(claudeSession).jsonl"])

        XCTAssertNil(
            TranscriptLocator.locate(
                sessionLabel: HookCaptureRedactor.label(forRawIdentifier: "00000000-0000-0000-0000-000000000000"),
                source: .claude,
                root: root
            )
        )
    }

    func testTheDefaultRootsAreTheOnesTheAgentsUse() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

        XCTAssertEqual(
            TranscriptLocator.defaultRoot(for: .claude, home: home).path,
            "/Users/someone/.claude/projects"
        )
        XCTAssertEqual(
            TranscriptLocator.defaultRoot(for: .codex, home: home).path,
            "/Users/someone/.codex/sessions"
        )
    }

    /// A Codex started with `CODEX_HOME` writes into its own folder's `sessions`, and the
    /// default folder has nothing for it. The search goes on to the next root.
    func testATranscriptInAListedFolderIsFoundAfterTheDefaultOne() throws {
        let defaultRoot = try makeRoot(named: [
            "2026/10/09/rollout-2026-10-09T01-00-00-8e341560-0990-4ff5-89d9-02ad3ae9e315.jsonl"
        ])
        let listedRoot = try makeRoot(named: ["2026/10/09/rollout-2026-10-09T01-10-29-\(codexSession).jsonl"])

        let found = TranscriptLocator.locate(
            sessionLabel: HookCaptureRedactor.label(forRawIdentifier: codexSession),
            source: .codex,
            roots: [defaultRoot, listedRoot]
        )

        XCTAssertEqual(found?.lastPathComponent, "rollout-2026-10-09T01-10-29-\(codexSession).jsonl")
        XCTAssertEqual(
            found.flatMap { TranscriptLocator.root(containing: $0, among: [defaultRoot, listedRoot]) }, listedRoot,
            "the thread index is read beside the root the transcript came from")
    }

    func testEachFolderKeepsItsTranscriptsWhereItsAgentWritesThem() {
        let folders = AgentFolders(
            home: URL(fileURLWithPath: "/Users/someone"), extra: [.codex: ["/Users/someone/.codex-work"]])

        XCTAssertEqual(
            TranscriptLocator.roots(for: .codex, in: folders).map(\.path),
            ["/Users/someone/.codex/sessions", "/Users/someone/.codex-work/sessions"])
        XCTAssertEqual(
            TranscriptLocator.roots(for: .claude, in: folders).map(\.path), ["/Users/someone/.claude/projects"])
    }

    private func makeRoot(named relativePaths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchLocatorTests.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for relativePath in relativePaths {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        return root
    }
}
