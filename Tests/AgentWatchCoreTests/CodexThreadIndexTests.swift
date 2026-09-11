import Foundation
import XCTest

@testable import AgentWatchCore

/// Codex keeps a thread's name away from its transcript, in one small index keyed by the raw
/// session identifier. The app never holds a raw identifier, so it does what it already does
/// to find a transcript: hashes every candidate and looks for its own label.
final class CodexThreadIndexTests: XCTestCase {
    private let sessionUUID = "01a05e55-adab-7881-abc6-b9fe09056a27"
    private let otherUUID = "019dcf8f-dbab-7573-8b4e-00720b3d58c3"

    func testAThreadIsFoundByHashingTheIdentifiersInTheIndex() {
        let index = Data(
            """
            {"id":"\(otherUUID)","thread_name":"someone else's thread"}
            {"id":"\(sessionUUID)","thread_name":"Разобрать тред и задачи"}
            """.utf8)

        let name = CodexThreadIndex.threadName(
            forSessionLabel: HookCaptureRedactor.label(forRawIdentifier: sessionUUID),
            inIndex: index
        )

        XCTAssertEqual(name, "Разобрать тред и задачи")
    }

    /// A thread is written again when it is renamed, and the placeholder it started with
    /// stays in the file above the real name. Measured in a real index: two of 137 threads
    /// appear twice, both going from `New voice chat` to what the thread is actually about.
    /// Catching the placeholder would be worse than not catching up at all.
    func testTheLastNameAThreadWasGivenIsTheOneItGoesBy() {
        let index = Data(
            """
            {"id":"\(sessionUUID)","thread_name":"New voice chat"}
            {"id":"\(otherUUID)","thread_name":"someone else's thread"}
            {"id":"\(sessionUUID)","thread_name":"Realtime Voice Chat"}
            """.utf8)

        let name = CodexThreadIndex.threadName(
            forSessionLabel: HookCaptureRedactor.label(forRawIdentifier: sessionUUID),
            inIndex: index
        )

        XCTAssertEqual(name, "Realtime Voice Chat")
    }

    /// The index is a file on disk that is appended to while this reads it, so the last line
    /// can be half written — and the format is undocumented and has changed before. Neither
    /// may cost the thread below it.
    func testAnUnreadableLineDoesNotHideTheThreadsBelowIt() {
        let index = Data(
            """
            {"id":"\(sessionUUID)","thread_name
            {"id":"\(sessionUUID)","thread_name":"Разобрать тред и задачи"}
            """.utf8)

        let name = CodexThreadIndex.threadName(
            forSessionLabel: HookCaptureRedactor.label(forRawIdentifier: sessionUUID),
            inIndex: index
        )

        XCTAssertEqual(name, "Разобрать тред и задачи")
    }

    /// Codex writes hooks for internal service sessions that never enter this index at all,
    /// and a thread can be in it before it has been named.
    func testAThreadTheIndexDoesNotNameHasNoName() {
        let index = Data(
            """
            {"id":"\(otherUUID)","thread_name":"someone else's thread"}
            {"id":"\(sessionUUID)"}
            """.utf8)

        XCTAssertNil(
            CodexThreadIndex.threadName(
                forSessionLabel: HookCaptureRedactor.label(forRawIdentifier: sessionUUID),
                inIndex: index
            )
        )
    }
}
