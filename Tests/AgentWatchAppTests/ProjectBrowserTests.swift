import AgentWatchLookup
import AgentWatchTestSupport
import Foundation
import XCTest

@testable import AgentWatchApp
@testable import AgentWatchCore

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
    func testNavigatingStartsTheChosenScopeWithoutAnOldSearchOrFilter() {
        let model = ProjectBrowserModel()
        defer { model.stop() }
        model.scope = .profiles
        model.search = "an old search"
        model.filter = .quiet
        model.navigate(to: .recent)
        XCTAssertEqual(model.scope, .recent)
        XCTAssertTrue(model.search.isEmpty)
        XCTAssertEqual(model.filter, .all)
    }

    /// A new chat appearing while a click is being resolved rereads the list; the click still
    /// opens the chat it was made on. Only closing the window drops it.
    @MainActor
    func testAClickSurvivesARereadForANewChat() async {
        let folders = AgentFolders(
            home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let chat = testSession(index: 1, phase: .waitingForUser, clientKind: .desktop, lastObservedAt: now)
        let newcomer = testSession(index: 2, phase: .executing, clientKind: .desktop, lastObservedAt: now)
        let link = URL(string: "claude://resume?session=chat")!
        let model = ProjectBrowserModel()
        defer { model.stop() }
        model.locate = { _, _ in ProjectSessionLocation(link: link, directory: nil) }
        let opened = expectation(description: "the chat's link reaches macOS")
        var links: [URL] = []
        model.openLink = {
            links.append($0)
            opened.fulfill()
            return true
        }
        model.update([chat], folders: folders, claudeUsage: [:], readsTranscripts: false)

        model.open(ProjectBrowserEntry(session: chat, copy: nil))
        model.update([chat, newcomer], folders: folders, claudeUsage: [:], readsTranscripts: false)

        await fulfillment(of: [opened], timeout: 5)
        XCTAssertEqual(links, [link])
        XCTAssertNil(model.message)
    }

    /// The waiting filter and the waiting beacon's list agree: a Codex question counts while the
    /// chat keeps working, and an answered one leaves both.
    @MainActor
    func testTheWaitingFilterMatchesTheBeaconsList() {
        var question = testSession(index: 1, source: .codex, phase: .executing, lastObservedAt: now)
        question.pendingCodexQuestions = ["question-1": now]
        let reply = testSession(index: 2, phase: .waitingForUser, lastObservedAt: now)
        let working = testSession(index: 3, phase: .executing, lastObservedAt: now)
        var answered = question
        answered.pendingCodexQuestions = nil
        let beacon = WaitingChatsModel { _ in .raised }
        for sessions in [[question, reply, working], [answered, reply, working]] {
            beacon.update(sessions)
            let filtered = sessions.filter { ProjectBrowserFilter.waiting.includes($0, now: now) }
            XCTAssertEqual(Set(filtered.map(\.id)), Set(beacon.rows.map(\.id)))
        }
        XCTAssertEqual(beacon.rows.map(\.id), [reply.id])
    }

    func testFiltersRunBeforeLimitAndUseTheRecordedPhaseAndAge() throws {
        // Spelled-out types: the CI compiler gave up inferring this closure in time.
        let entries: [ProjectBrowserEntry] = (0...25).map { (index: Int) -> ProjectBrowserEntry in
            let first = index == 0
            let source: AgentSource = first ? .claude : .codex
            let phase: SessionPhase = first ? .waitingForUser : .executing
            let observed: Date = now.addingTimeInterval(Double(index) - 80)
            let session = testSession(
                index: index, source: source, title: "Chat \(index)", phase: phase, lastObservedAt: observed)
            return ProjectBrowserEntry(session: session, copy: nil)
        }
        func list(_ filter: ProjectBrowserFilter, search: String = "") -> [ProjectBrowserEntry] {
            ProjectBrowserCatalog.visible(entries, scope: .recent, filter: filter, search: search, now: now)
        }
        XCTAssertEqual(list(.all).count, ProjectBrowserCatalog.recentLimit)
        XCTAssertEqual(list(.all).first?.session.title, "Chat 25")
        XCTAssertEqual(list(.waiting).map(\.id), [entries[0].id])
        XCTAssertEqual(list(.working, search: "CLAUDE").count, 0)
        XCTAssertEqual(list(.all, search: "CLAUDE").map(\.id), [entries[0].id])
        let quiet: [ProjectBrowserEntry] = Array(entries[1...20].reversed())
        XCTAssertEqual(list(.quiet).map(\.id), quiet.map(\.id))
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
