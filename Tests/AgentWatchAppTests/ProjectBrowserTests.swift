import AgentWatchCore
import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchApp

final class ProjectBrowserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_000)

    func testSidebarAcceptsOnlyTheThreeNavigationLinks() {
        for destination in WatchDestination.allCases {
            let url = URL(string: "agentwatch://" + destination.rawValue)
            XCTAssertEqual(url.flatMap { WatchDestination(url: $0, development: false) }, destination)
        }
        let dev = URL(string: "agentwatch-dev://waiting")!
        XCTAssertEqual(WatchDestination(url: dev, development: true), .waiting)
        XCTAssertNil(WatchDestination(url: dev, development: false))
        XCTAssertNil(WatchDestination(url: URL(string: "agentwatch://waiting")!, development: true))
        for invalid in [
            "https://projects", "agentwatch://unknown", "agentwatch://settings?execute=true",
            "agentwatch://waiting/extra", "agentwatch://user@projects",
        ] {
            XCTAssertNil(URL(string: invalid).flatMap { WatchDestination(url: $0, development: false) })
        }
    }

    @MainActor
    func testWaitingDestinationOpensAllInteractiveWaitsAndDropsResolvedChats() {
        let waiting = (0...22).map { index in
            testSession(
                index: index, source: index.isMultiple(of: 2) ? .claude : .codex,
                phase: .waitingForUser, clientKind: index.isMultiple(of: 2) ? .cli : .desktop,
                lastObservedAt: now.addingTimeInterval(Double(index)))
        }
        let other = [
            testSession(index: 23, phase: .executing, lastObservedAt: now),
            testSession(index: 24, phase: .failed, lastObservedAt: now),
            testSession(index: 25, phase: .waitingForUser, clientKind: .headless, lastObservedAt: now),
        ]
        let folders = AgentFolders(
            home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let model = ProjectBrowserModel()
        defer { model.stop() }
        model.update(waiting + other, folders: folders, claudeUsage: [:], readsTranscripts: false)
        model.scope = .profiles
        model.search = "an old search"
        model.filter = .quiet
        model.navigate(to: .waiting)
        XCTAssertEqual(model.scope, .waiting)
        XCTAssertTrue(model.search.isEmpty)
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.waiting.map(\.id), waiting.reversed().map(\.id))
        model.update(other, folders: folders, claudeUsage: [:], readsTranscripts: false)
        XCTAssertTrue(model.waiting.isEmpty)
    }

    func testFiltersRunBeforeLimitAndUseTheRecordedPhaseAndAge() throws {
        let entries = (0...25).map { index in
            ProjectBrowserEntry(
                session: testSession(
                    index: index, source: index == 0 ? .claude : .codex, title: "Chat \(index)",
                    phase: index == 0 ? .waitingForUser : .executing,
                    lastObservedAt: now.addingTimeInterval(Double(index) - 80)), copy: nil)
        }
        func list(_ filter: ProjectBrowserFilter, search: String = "") -> [ProjectBrowserEntry] {
            ProjectBrowserCatalog.visible(entries, scope: .recent, filter: filter, search: search, now: now)
        }
        XCTAssertEqual(list(.all).count, ProjectBrowserCatalog.recentLimit)
        XCTAssertEqual(list(.all).first?.session.title, "Chat 25")
        XCTAssertEqual(list(.waiting).map(\.id), [entries[0].id])
        XCTAssertEqual(list(.working, search: "CLAUDE").count, 0)
        XCTAssertEqual(list(.all, search: "CLAUDE").map(\.id), [entries[0].id])
        XCTAssertEqual(list(.quiet).map(\.id), entries[1...20].reversed().map(\.id))
    }

    @MainActor
    func testChangingTranscriptAccessInvalidatesProjectAndArchiveEvidence() async throws {
        let scratch =
            ProcessInfo.processInfo.environment["AGENT_WATCH_TEST_SCRATCH"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = scratch.appendingPathComponent(UUID().uuidString)
        let folders = AgentFolders(home: home)
        let root = TranscriptLocator.defaultRoot(for: .codex, home: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-c", "init.templateDir=", "init", "--quiet", home.path]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        let id = UUID().uuidString.lowercased()
        let file = root.appendingPathComponent("rollout-" + id + ".jsonl")
        let metadata: [String: Any] = ["type": "session_meta", "payload": ["id": id, "cwd": home.path]]
        var data = try JSONSerialization.data(withJSONObject: metadata)
        data.append(10)
        try data.write(to: file)
        let row = SessionSnapshot(
            id: SessionSnapshot.id(source: .codex, sessionLabel: HookCaptureRedactor.label(forRawIdentifier: id)),
            source: .codex, arrivalIndex: 0, phase: .executing, lastObservedAt: now, clientKind: .desktop)
        let model = ProjectBrowserModel()
        defer { model.stop() }
        func setReading(_ enabled: Bool) async throws {
            model.update([row], folders: folders, claudeUsage: [:], readsTranscripts: enabled)
            for _ in 0..<120 where model.reading { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertFalse(model.reading)
        }
        try await setReading(true)
        XCTAssertEqual(try XCTUnwrap(model.entries.first?.copy).root.path, home.resolvingSymlinksInPath().path)
        try await setReading(false)
        XCTAssertEqual(model.entries.map(\.id), [row.id])
        XCTAssertNil(model.entries.first?.copy)
        let archive = TranscriptLocator.codexArchivedSessions(inRoot: root)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        try await setReading(true)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testCompletedTurnFollowsCurrentChatsAndProjectScopeIsNotCapped() {
        let entries = (0...22).map { index in
            ProjectBrowserEntry(
                session: testSession(
                    index: index, phase: index == 22 ? .completed : .executing,
                    lastObservedAt: now.addingTimeInterval(Double(index))), copy: nil)
        }
        let rows = ProjectBrowserCatalog.visible(entries, scope: .unknown, filter: .all, search: "", now: now)
        XCTAssertEqual(rows.count, entries.count)
        XCTAssertEqual(rows.last?.id, entries[22].id)
        XCTAssertEqual(rows.first?.id, entries[21].id)
    }
}
