import AgentWatchCore
import Foundation
import XCTest

@testable import AgentWatchSender

/// The on-disk shapes parsed here are undocumented internals of Claude Code and Codex.
/// These tests pin what today's files look like so a future format change fails loudly
/// in CI rather than silently dropping the topic from the widget.
final class SessionDescriptionResolverTests: XCTestCase {
    func testReadsTheCurrentClaudeTitleFromATranscriptTail() {
        let tail = lines([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"ai-title","aiTitle":"Первый заголовок","sessionId":"abc"}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
            #"{"type":"ai-title","aiTitle":"AGENTS.md интеграция в CLAUDE.md","sessionId":"abc"}"#,
        ])

        XCTAssertEqual(
            SessionDescriptionResolver.claudeDescription(inTranscriptTail: tail).title,
            "AGENTS.md интеграция в CLAUDE.md",
            "Claude rewrites the title as the topic evolves, so the last one wins"
        )
    }

    func testATruncatedFirstLineDoesNotAbortTheScan() {
        let tail = Data(
            (#"aiTitle":"обрезанный мусор"}"# + "\n"
                + #"{"type":"ai-title","aiTitle":"Целый заголовок","sessionId":"abc"}"# + "\n").utf8
        )

        XCTAssertEqual(SessionDescriptionResolver.claudeDescription(inTranscriptTail: tail).title, "Целый заголовок")
    }

    func testATranscriptWithoutATitleYieldsNothing() {
        let tail = lines([#"{"type":"user","message":{"role":"user"}}"#])

        XCTAssertNil(SessionDescriptionResolver.claudeDescription(inTranscriptTail: tail).title)
    }

    func testReadsTheCodexThreadNameForTheMatchingSession() {
        let index = lines([
            #"{"id":"other","thread_name":"Чужая ветка","updated_at":"2026-09-01T18:57:29Z"}"#,
            #"{"id":"mine","thread_name":"Спроектировать мониторинг AI-сессий","updated_at":"2026-09-02T21:59:36Z"}"#,
        ])

        XCTAssertEqual(
            Self.codexResolution(of: "mine", in: index).description?.title,
            "Спроектировать мониторинг AI-сессий"
        )
        let absent = Self.codexResolution(of: "absent", in: index)
        XCTAssertNil(absent.description)
        XCTAssertFalse(absent.isIndexed, "a session the index does not name is not a session to report")
    }

    func testCodexSessionWithoutANameIsStillIndexed() {
        let index = {
            var data = lines([#"{"id":"new-thread"}"#])
            data.append(Data(repeating: 0x20, count: SessionDescriptionResolver.transcriptTailByteCount + 1))
            return data
        }()
        let fileSystem = TitleFileSystem(readTail: { _, byteCount in
            // This is an admission check, so it must cover the index rather than merely its
            // usual title-search tail. The matching record above sits outside that tail, and
            // returning no data for a bounded read pins the whole-index contract.
            byteCount == Int.max ? index : nil
        })

        let resolution = SessionDescriptionResolver.resolveCodexSession(
            payload: .object([
                "session_id": .string("new-thread"),
                "cwd": .string("/Users/ilya/Projects/agent-watch"),
            ]),
            indexPath: "/tmp/session_index.jsonl",
            fileSystem: fileSystem
        )

        XCTAssertTrue(resolution.isIndexed)
        XCTAssertNil(resolution.description?.title)
        XCTAssertEqual(resolution.description?.projectName, "agent-watch")
    }

    func testCodexServiceSessionOutsideTheIndexIsNotAdmitted() {
        let index = lines([#"{"id":"user-thread","thread_name":"Visible"}"#])
        let fileSystem = TitleFileSystem(readTail: { _, _ in index })

        let resolution = SessionDescriptionResolver.resolveCodexSession(
            payload: .object(["session_id": .string("service-thread")]),
            indexPath: "/tmp/session_index.jsonl",
            fileSystem: fileSystem
        )

        XCTAssertFalse(resolution.isIndexed)
        XCTAssertNil(resolution.description)
    }

    func testALaterCodexEntrySupersedesAnEarlierOne() {
        let index = lines([
            #"{"id":"mine","thread_name":"Старое имя"}"#,
            #"{"id":"mine","thread_name":"Новое имя"}"#,
        ])

        XCTAssertEqual(Self.codexResolution(of: "mine", in: index).description?.title, "Новое имя")
    }

    /// A session already running when the widget starts has to pick its name up from
    /// whatever event comes next, not from the end of its next turn.
    ///
    /// The resolver takes no event name at all — that is the mechanism, and this asserts it
    /// by exhausting the parameters that exist. A gate on the event could only come back as
    /// a new parameter, and this test would then stop compiling.
    func testNothingAboutTheEventCanChangeWhatIsResolved() {
        let reads = ReadCounter()
        let fileSystem = TitleFileSystem(readTail: { _, _ in
            reads.count += 1
            return Data(#"{"type":"ai-title","aiTitle":"Из транскрипта"}"#.utf8)
        })
        let payload = JSONValue.object([
            "session_id": .string("raw-uuid"),
            "transcript_path": .string("/tmp/transcript.jsonl"),
            "cwd": .string("/Users/x/CommonProjects/agent-watch"),
            // Present in a real payload and deliberately not consulted: the declared event
            // travels beside the payload, and the resolver never looks at either.
            "hook_event_name": .string("PreToolUse"),
        ])

        let first = SessionDescriptionResolver.resolve(source: .claude, payload: payload, fileSystem: fileSystem)
        let second = SessionDescriptionResolver.resolve(source: .claude, payload: payload, fileSystem: fileSystem)

        XCTAssertEqual(first?.title, "Из транскрипта")
        XCTAssertEqual(first, second, "the same inputs answer the same, whatever event carried them")
        XCTAssertEqual(reads.count, 2, "and the file is read every time, not once per turn")
    }

    // MARK: - Everything else a description carries

    func testReadsTheBranchAndTheContextSizeFromTheSameTail() throws {
        let tail = lines([
            #"{"type":"user","cwd":"/Users/x/CommonProjects/agent-watch","gitBranch":"main"}"#,
            #"{"type":"ai-title","aiTitle":"Заголовок"}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":2,"cache_read_input_tokens":332169,"cache_creation_input_tokens":640,"output_tokens":439}}}"#,
        ])

        let description = SessionDescriptionResolver.claudeDescription(inTranscriptTail: tail)

        XCTAssertEqual(description.title, "Заголовок")
        XCTAssertEqual(description.gitBranch, "main")
        XCTAssertEqual(description.contextInputTokens, 332_811, "output tokens are not in the window")
    }

    /// A transcript is a file on disk, and a number in it must never be able to kill the
    /// hook process. `Int(1e30)` traps, and so does a sum that overflows.
    func testAnImpossibleTokenCountIsRefusedRatherThanConverted() {
        let huge = #"{"message":{"usage":{"input_tokens":1e30}}}"#
        let negative = #"{"message":{"usage":{"input_tokens":-5}}}"#
        let overflowing =
            #"{"message":{"usage":{"input_tokens":9e18,"cache_read_input_tokens":9e18}}}"#

        for line in [huge, negative, overflowing] {
            XCTAssertNil(
                SessionDescriptionResolver.claudeDescription(inTranscriptTail: lines([line]))
                    .contextInputTokens,
                "\(line) must degrade to no answer, not to a crash"
            )
        }
    }

    func testATranscriptWithNoUsageBlockReportsNoContextSize() {
        let tail = lines([#"{"type":"assistant","message":{"role":"assistant"}}"#])

        XCTAssertNil(SessionDescriptionResolver.claudeDescription(inTranscriptTail: tail).contextInputTokens)
    }

    /// Only the directory's own name travels. See `docs/architecture.md` §15.
    func testOnlyTheLastComponentOfTheWorkingDirectoryTravels() {
        XCTAssertEqual(
            SessionDescriptionResolver.projectName(inWorkingDirectory: "/Users/x/CommonProjects/agent-watch"),
            "agent-watch"
        )
        XCTAssertEqual(SessionDescriptionResolver.projectName(inWorkingDirectory: "/Users/x/repo/"), "repo")
        XCTAssertNil(SessionDescriptionResolver.projectName(inWorkingDirectory: "/"))
        XCTAssertNil(SessionDescriptionResolver.projectName(inWorkingDirectory: ""))
    }

    func testTheProjectNameComesFromThePayloadForBothAgents() {
        let empty = TitleFileSystem(readTail: { _, _ in nil })

        for source in [AgentSource.claude, .codex] {
            XCTAssertEqual(
                SessionDescriptionResolver.resolve(
                    source: source,
                    payload: .object(["cwd": .string("/Users/x/CommonProjects/agent-watch")]),
                    fileSystem: empty
                )?.projectName,
                "agent-watch",
                "\(source) reports its working directory in the hook payload"
            )
        }
    }

    func testResolveReadsTheTranscriptPathClaudeSuppliedInTheRawPayload() {
        let requestedPath = RecordedPath()
        let fileSystem = TitleFileSystem(
            readTail: { path, _ in
                requestedPath.value = path
                return Data(#"{"type":"ai-title","aiTitle":"Из транскрипта"}"#.utf8)
            },
        )

        let description = SessionDescriptionResolver.resolve(
            source: .claude,
            payload: .object([
                "session_id": .string("raw-uuid"),
                "transcript_path": .string("/tmp/transcript.jsonl"),
            ]),
            fileSystem: fileSystem
        )

        XCTAssertEqual(description?.title, "Из транскрипта")
        XCTAssertEqual(requestedPath.value, "/tmp/transcript.jsonl")
    }

    func testAnUnreadableFileResolvesToNoTitleRatherThanAnError() {
        let fileSystem = TitleFileSystem(readTail: { _, _ in nil })

        XCTAssertNil(
            SessionDescriptionResolver.resolve(
                source: .claude,
                payload: .object(["transcript_path": .string("/nope")]),
                fileSystem: fileSystem
            )
        )
    }

    func testAClaudePayloadWithoutATranscriptPathResolvesToNoTitle() {
        let reads = RecordedPath()
        let fileSystem = TitleFileSystem(
            readTail: { path, _ in
                reads.value = path
                return nil
            }
        )

        XCTAssertNil(
            SessionDescriptionResolver.resolve(
                source: .claude,
                payload: .object(["session_id": .string("raw-uuid")]),
                fileSystem: fileSystem
            )
        )
        XCTAssertNil(reads.value, "without a path there is nothing to read")
    }

    func testResolveReadsTheCodexIndexAtTheGivenPath() {
        let requestedPath = RecordedPath()
        let fileSystem = TitleFileSystem(readTail: { path, _ in
            requestedPath.value = path
            return Data(#"{"id":"raw-uuid","thread_name":"Из индекса тредов"}"#.utf8)
        })

        let description = SessionDescriptionResolver.resolve(
            source: .codex,
            payload: .object(["session_id": .string("raw-uuid")]),
            codexIndexPath: "/tmp/session_index.jsonl",
            fileSystem: fileSystem
        )

        XCTAssertEqual(description?.title, "Из индекса тредов")
        XCTAssertEqual(requestedPath.value, "/tmp/session_index.jsonl")
    }

    func testACodexPayloadWithoutASessionIDResolvesToNoTitle() {
        let reads = RecordedPath()
        let fileSystem = TitleFileSystem(readTail: { path, _ in
            reads.value = path
            return nil
        })

        XCTAssertNil(
            SessionDescriptionResolver.resolve(
                source: .codex,
                payload: .object([:]),
                fileSystem: fileSystem
            )
        )
        XCTAssertNil(reads.value)
    }

    /// Both branches, rather than whichever one this machine happens to be in. The variable
    /// is set for the duration of the check and put back afterwards.
    func testTheCodexIndexPathFollowsCodexHomeWhenItIsSet() {
        let previous = ProcessInfo.processInfo.environment["CODEX_HOME"]
        defer {
            if let previous {
                setenv("CODEX_HOME", previous, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        setenv("CODEX_HOME", "/tmp/elsewhere", 1)
        XCTAssertEqual(SessionDescriptionResolver.codexSessionIndexPath(), "/tmp/elsewhere/session_index.jsonl")

        unsetenv("CODEX_HOME")
        let fallback = SessionDescriptionResolver.codexSessionIndexPath()
        XCTAssertTrue(fallback.hasSuffix("/.codex/session_index.jsonl"), "got \(fallback)")
    }

    // MARK: - The real file read

    func testTheLiveReadReturnsOnlyTheTailOfALongFile() throws {
        let url = try makeTemporaryFile(contents: String(repeating: "a", count: 500) + "TAIL")

        let data = TitleFileSystem.live.readTail(url.path, 16)

        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "aaaaaaaaaaaaTAIL")
    }

    func testTheLiveReadReturnsAShortFileWhole() throws {
        let url = try makeTemporaryFile(contents: "короткий")

        let data = TitleFileSystem.live.readTail(url.path, 64 * 1024)

        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "короткий")
    }

    func testTheLiveReadHandlesAnEmptyFileAndAMissingOne() throws {
        let url = try makeTemporaryFile(contents: "")

        // `readToEnd` reports nothing rather than empty data at EOF; either way there is
        // no title to find, which is all the caller needs.
        XCTAssertTrue(TitleFileSystem.live.readTail(url.path, 1_024)?.isEmpty ?? true)
        XCTAssertNil(TitleFileSystem.live.readTail("/nonexistent/session_index.jsonl", 1_024))
        XCTAssertNil(TitleFileSystem.live.readTail(url.path, 0))
    }

    private func makeTemporaryFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-watch-title-\(UUID().uuidString).jsonl")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func lines(_ values: [String]) -> Data {
        Data((values.joined(separator: "\n") + "\n").utf8)
    }

    /// Through the one entry point production uses. Reading the index for a title and reading
    /// it to decide whether the session is one of ours is the same read, and a test that goes
    /// straight at the lookup would pass with that read wired to nothing.
    private static func codexResolution(of sessionID: String, in index: Data) -> CodexSessionResolution {
        SessionDescriptionResolver.resolveCodexSession(
            payload: .object(["session_id": .string(sessionID)]),
            indexPath: "/tmp/session_index.jsonl",
            fileSystem: TitleFileSystem(readTail: { _, _ in index })
        )
    }
}

/// The resolver takes `@Sendable` closures, so a captured local cannot record the call.
private final class RecordedPath: @unchecked Sendable {
    var value: String?
}

/// Counts reads from inside a `@Sendable` closure.
private final class ReadCounter: @unchecked Sendable {
    var count = 0
}
