import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp
@testable import AgentWatchCore

@MainActor
final class WaitingChatsTests: XCTestCase {
    func testEqualCountsStillReplaceAnsweredChatsAndFocusOnlyTheSelectedConversation() {
        let start = Date(timeIntervalSince1970: 100)
        let first = testSession(index: 1, source: .codex, phase: .waitingForUser, lastObservedAt: start)
        let second = testSession(
            index: 2, source: .claude, phase: .waitingForUser, lastObservedAt: start.addingTimeInterval(1))
        let headless = testSession(index: 3, phase: .waitingForUser, clientKind: .headless, lastObservedAt: start)
        let third = testSession(
            index: 4, source: .codex, phase: .waitingForUser, lastObservedAt: start.addingTimeInterval(2))
        var focused: [String] = []
        let model = WaitingChatsModel { id in
            focused.append(id)
            return .raised
        }

        model.update([first, headless, second])
        XCTAssertEqual(model.rows.map(\.id), [second.id, first.id])
        XCTAssertTrue(model.open(first.id))
        model.update([third, second])
        XCTAssertEqual(model.rows.map(\.id), [third.id, second.id])
        XCTAssertFalse(model.open(first.id))
        XCTAssertTrue(model.open(second.id))
        XCTAssertEqual(focused, [first.id, second.id])
        model.update([])
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testCodexCanKeepWorkingWhileItsQuestionIsInTheList() {
        var session = testSession(source: .codex, phase: .executing, lastObservedAt: .now)
        session.pendingCodexQuestions = ["question-1": .now]
        let model = WaitingChatsModel { _ in .raised }
        model.update([session])
        XCTAssertEqual(model.rows.map(\.id), [session.id])
        session.pendingCodexQuestions = nil
        model.update([session])
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testDesktopBeaconSucceedsOnlyWhenTheSelectedChatLinkWasSent() throws {
        var opened: [URL] = []
        var accepted = true
        func follow(_ route: SessionHostRegistry.TabRoute) -> TabFocusAttempt {
            guard case let .desktopClient(url) = route else {
                XCTFail("Expected a chat link")
                return .unaddressable
            }
            opened.append(url)
            return accepted ? .asked : .missing("No handler")
        }
        let missing = SessionHostRegistry.openDesktopChat(.noTab(.missing("No matching transcript")), follow: follow)
        XCTAssertFalse(missing.raised)
        XCTAssertEqual(missing.tab, .missing("No matching transcript"))
        XCTAssertTrue(opened.isEmpty)
        for target in ["codex://threads/test-thread", "claude://code/continue?session=local_test"] {
            let url = try XCTUnwrap(URL(string: target))
            accepted = false
            XCTAssertFalse(SessionHostRegistry.openDesktopChat(.desktopClient(url), follow: follow).raised)
            accepted = true
            XCTAssertTrue(SessionHostRegistry.openDesktopChat(.desktopClient(url), follow: follow).raised)
            XCTAssertEqual(opened.suffix(2), [url, url])
        }
    }

    func testUnavailableChatCanBeRetriedWhileItStillNeedsAnAnswer() {
        let session = testSession(phase: .waitingForUser, lastObservedAt: .now)
        var result = SessionClick.nothingRaised
        let model = WaitingChatsModel { _ in result }
        model.update([session])
        XCTAssertFalse(model.open(session.id))
        XCTAssertEqual(model.unavailableID, session.id)
        result = .raised
        XCTAssertTrue(model.open(session.id))
        XCTAssertNil(model.unavailableID)
    }
}
