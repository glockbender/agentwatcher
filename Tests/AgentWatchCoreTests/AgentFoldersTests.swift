import Foundation
import XCTest

@testable import AgentWatchCore

/// The folders each agent keeps its files in, and how the two sides of the socket agree on
/// which one an event came from without a path ever crossing it.
final class AgentFoldersTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testEachAgentHasItsDefaultFolderFirst() {
        let folders = AgentFolders(
            home: home, extra: [.codex: ["/Users/someone/.codex-work", "/Users/someone/.codex-personal"]])

        XCTAssertEqual(
            folders.folders(for: .codex).map(\.path),
            ["/Users/someone/.codex", "/Users/someone/.codex-work", "/Users/someone/.codex-personal"])
        XCTAssertEqual(folders.folders(for: .claude).map(\.path), ["/Users/someone/.claude"])
    }

    /// The same folder twice would mean the same hooks installed twice and two rows arguing
    /// about one file; a relative path says nothing about where it is.
    func testAFolderIsListedOnceAndOnlyWhenItIsAnAbsolutePath() {
        let folders = AgentFolders(
            home: home,
            extra: [
                .codex: [
                    "/Users/someone/.codex", "/Users/someone/.codex-work", "/Users/someone/.codex-work/",
                    ".codex-relative", "",
                ]
            ])

        XCTAssertEqual(folders.extraFolders(for: .codex).map(\.path), ["/Users/someone/.codex-work"])
    }

    /// Measured on Claude Code 2.1.294 and Codex 0.161.0, in folders named by the variable.
    func testTheFolderIsReadFromWhereEachAgentWritesItsTranscript() {
        XCTAssertEqual(
            AgentFolders.folder(
                ofTranscriptAt: "/Users/someone/.claude-work/projects/-Users-someone-app/5f1c2d3e.jsonl",
                source: .claude)?.path,
            "/Users/someone/.claude-work")
        XCTAssertEqual(
            AgentFolders.folder(
                ofTranscriptAt: "/Users/someone/.codex-work/sessions/2026/10/09/rollout-2026-10-09T01-10-29-01a1.jsonl",
                source: .codex)?.path,
            "/Users/someone/.codex-work")
    }

    func testAPathOfNeitherShapeNamesNoFolder() {
        XCTAssertNil(AgentFolders.folder(ofTranscriptAt: "/Users/someone/notes/today.jsonl", source: .claude))
        XCTAssertNil(
            AgentFolders.folder(ofTranscriptAt: "/Users/someone/.codex/archived_sessions/rollout.jsonl", source: .codex)
        )
        XCTAssertNil(AgentFolders.folder(ofTranscriptAt: "/projects/app/5f1c2d3e.jsonl", source: .claude))
    }

    /// The transcript first, because that is the agent saying where it writes; the variable
    /// for a hook that names none; the default folder for an agent started without one.
    func testTheReportingFolderPrefersTheTranscriptThenTheVariableThenTheDefault() {
        let transcript = "/Users/someone/.codex-work/sessions/2026/10/09/rollout-x.jsonl"
        let variable = ["CODEX_HOME": "/Users/someone/.codex-personal"]

        XCTAssertEqual(
            AgentFolders.reportingFolder(source: .codex, transcriptPath: transcript, environment: variable, home: home)
                .path,
            "/Users/someone/.codex-work")
        XCTAssertEqual(
            AgentFolders.reportingFolder(source: .codex, transcriptPath: nil, environment: variable, home: home).path,
            "/Users/someone/.codex-personal")
        XCTAssertEqual(
            AgentFolders.reportingFolder(
                source: .claude, transcriptPath: nil, environment: ["CLAUDE_CONFIG_DIR": "relative"], home: home
            ).path,
            "/Users/someone/.claude")
    }

    /// The sender starts from the path the agent wrote under and the app from the path a person
    /// picked. `/tmp` is a link, so the same folder reaches the two sides spelled two ways. A
    /// real folder, because both spellings meet only for a folder that is there — and an agent
    /// writes only into one that is.
    func testOneFolderSpelledTwoWaysHasOneLabel() throws {
        let picked = URL(fileURLWithPath: "/tmp/agent-watch-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: picked) }
        let written = URL(fileURLWithPath: "/private" + picked.path, isDirectory: true)

        XCTAssertEqual(AgentFolders.label(of: picked), AgentFolders.label(of: written))
        XCTAssertNotEqual(AgentFolders.label(of: picked), AgentFolders.label(of: home))
    }

    func testAListedFolderIsFoundByItsLabel() {
        let work = URL(fileURLWithPath: "/Users/someone/.codex-work", isDirectory: true)
        let folders = AgentFolders(home: home, extra: [.codex: [work.path]])

        XCTAssertEqual(folders.folder(labelled: AgentFolders.label(of: work), for: .codex)?.path, work.path)
        XCTAssertNil(folders.folder(labelled: AgentFolders.label(of: work), for: .claude))
        XCTAssertTrue(folders.isDefault(URL(fileURLWithPath: "/Users/someone/.codex/"), for: .codex))
        XCTAssertFalse(folders.isDefault(work, for: .codex))
    }

    // MARK: - Across the socket

    /// Anything can write to the socket. The field is only compared, but nothing without a
    /// label's shape — a path above all — is kept.
    func testOnlyALabelShapedValueIsKept() {
        let label = AgentFolders.label(of: URL(fileURLWithPath: "/Users/someone/.codex-work"))

        XCTAssertEqual(HookIngressRequest.sanitizedFolderLabel(label), label)
        XCTAssertNil(HookIngressRequest.sanitizedFolderLabel("/Users/someone/.codex-work"))
        XCTAssertNil(HookIngressRequest.sanitizedFolderLabel(label.uppercased()))
        XCTAssertNil(HookIngressRequest.sanitizedFolderLabel(label + "0"))
        XCTAssertNil(HookIngressRequest.sanitizedFolderLabel("id_" + String(repeating: "g", count: 16)))
        XCTAssertNil(HookIngressRequest.sanitizedFolderLabel(nil))
    }

    /// A sender that predates the field still delivers, and its events count for the
    /// default folder.
    func testARequestWithoutTheFieldStillDecodes() throws {
        let json = #"{"schemaVersion":1,"source":"codex","declaredEvent":"Stop","payload":{"session_id":"x"}}"#

        let request = try JSONDecoder().decode(HookIngressRequest.self, from: Data(json.utf8))

        XCTAssertNil(request.agentFolderLabel)
    }
}
