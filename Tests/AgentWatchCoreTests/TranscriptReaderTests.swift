import Foundation
import XCTest

@testable import AgentWatchCore

/// The record shapes here are copied from real transcripts, reduced to the fields the reader
/// looks at. Inventing them would prove only that the reader agrees with the test's author.
final class TranscriptReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)
    private let rawToolUseID = "toolu_01CePmLevgH5XrWyBCgawVe9"
    /// The `srvtoolu_` prefix is the whole reason advisor is here: it marks a tool that runs
    /// on Anthropic's side rather than in the client, so no hook fires for it.
    private let rawAdvisorID = "srvtoolu_01JUmUTCNnZSEzFXFAkQQASJ"

    private func read(_ lines: [String], source: AgentSource = .claude) throws -> TranscriptIncrement {
        let text = lines.joined(separator: "\n") + "\n"
        return try TranscriptReader.read(
            increment: XCTUnwrap(text.data(using: .utf8)),
            source: source,
            observedAt: now
        )
    }

    // MARK: - What the reader is for

    /// The ending that `PostToolUse` reports only when the call succeeded. In the measured
    /// case the call was refused, the hook stayed silent, and this line was the only record.
    func testAToolResultEndsTheCall() throws {
        let increment = try read([
            """
            {"type":"user","timestamp":"2026-09-05T02:09:56.557Z","message":{"role":"user","content":\
            [{"type":"tool_result","tool_use_id":"\(rawToolUseID)","is_error":true}]}}
            """
        ])

        XCTAssertEqual(
            increment.facts,
            [
                .callReturned(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: rawToolUseID),
                    at: Date(timeIntervalSince1970: 1_788_574_196.557)
                )
            ]
        )
    }

    /// The only observation anywhere of a background command's real end. `status` is read as
    /// nothing more than "it is over": `killed` and `completed` both end the work.
    func testATaskNotificationEndsWorkThatOutlivedItsCall() throws {
        let increment = try read([
            """
            {"type":"user","timestamp":"2026-09-05T02:09:56Z","message":{"role":"user","content":\
            [{"type":"text","text":"<task-notification>\\n<task-id>b9qwjr452</task-id>\\n\
            <tool-use-id>\(rawToolUseID)</tool-use-id>\\n<status>killed</status>\\n</task-notification>"}]}}
            """
        ])

        XCTAssertEqual(
            increment.facts,
            [
                .workEnded(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: rawToolUseID),
                    at: Date(timeIntervalSince1970: 1_788_574_196)
                )
            ]
        )
    }

    // MARK: - Advisor

    /// The start of an advisor call, and the one fact this reader produces that opens an
    /// activity rather than closing one. Nothing else has to: everything the widget shows as
    /// running was announced by a hook first.
    func testAnAdvisorCallStartsAnActivityNoHookAnnounced() throws {
        let increment = try read([
            """
            {"type":"assistant","timestamp":"2026-09-03T23:22:49.253Z","message":{"role":"assistant",\
            "content":[{"type":"server_tool_use","id":"\(rawAdvisorID)","name":"advisor","input":{}}]}}
            """
        ])

        XCTAssertEqual(
            increment.facts,
            [
                .callStarted(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: rawAdvisorID),
                    kind: .advisor,
                    at: Date(timeIntervalSince1970: 1_788_477_769.253)
                )
            ]
        )
    }

    /// `advisor` is not the only tool that runs on Anthropic's side — a web search is written
    /// the same way. Counting those as advisor would put a lamp on work the widget has nothing
    /// to say about, and would name it wrongly besides.
    func testAnotherServerToolIsNotAnAdvisorCall() throws {
        let increment = try read([
            """
            {"type":"assistant","timestamp":"2026-09-03T23:22:49.253Z","message":{"role":"assistant",\
            "content":[{"type":"server_tool_use","id":"srvtoolu_websearch","name":"web_search","input":{}}]}}
            """
        ])

        XCTAssertEqual(increment.facts, [])
    }

    /// The end of an advisor call. Its record sits in `message.content` beside the
    /// `tool_result` above and names the call the same way, so this reader is the only place
    /// that can ever see it.
    func testAnAdvisorResultEndsTheCall() throws {
        let increment = try read([
            """
            {"type":"assistant","timestamp":"2026-09-03T23:24:17.096Z","message":{"role":"assistant",\
            "content":[{"type":"advisor_tool_result","tool_use_id":"\(rawAdvisorID)","content":{}}]}}
            """
        ])

        XCTAssertEqual(
            increment.facts,
            [
                .callReturned(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: rawAdvisorID),
                    at: Date(timeIntervalSince1970: 1_788_477_857.096)
                )
            ]
        )
    }

    /// Measured with a control: an interrupted turn delivers no hook at all, while the same
    /// session delivered `Stop` twice for turns that ended normally.
    func testTheInterruptionMarkerEndsTheTurn() throws {
        let increment = try read([
            """
            {"type":"user","timestamp":"2026-09-05T02:05:53Z","message":{"role":"user","content":\
            [{"type":"text","text":"[Request interrupted by user]"}]}}
            """,
            """
            {"type":"user","timestamp":"2026-09-05T02:05:53Z","message":{"role":"user","content":\
            [{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
            """,
        ])

        XCTAssertEqual(increment.facts.count, 2, "both wordings mean the turn is over")
        XCTAssertEqual(increment.facts.first, .turnInterrupted(at: Date(timeIntervalSince1970: 1_788_573_953)))
    }

    /// Codex pairs a call with its output by `call_id`, in two shapes. Measured on a live
    /// rollout file: 11 calls and 11 outputs, 3 and 3.
    func testCodexOutputsEndTheirCalls() throws {
        let increment = try read(
            [
                """
                {"type":"response_item","timestamp":"2026-09-05T02:09:56Z",\
                "payload":{"type":"custom_tool_call_output","call_id":"call_abc"}}
                """,
                """
                {"type":"response_item","timestamp":"2026-09-05T02:09:57Z",\
                "payload":{"type":"function_call_output","call_id":"call_def"}}
                """,
                """
                {"type":"response_item","timestamp":"2026-09-05T02:09:58Z",\
                "payload":{"type":"custom_tool_call","call_id":"call_ghi"}}
                """,
            ],
            source: .codex
        )

        XCTAssertEqual(
            increment.facts.map(\.endedActivityID),
            [
                HookCaptureRedactor.label(forRawIdentifier: "call_abc"),
                HookCaptureRedactor.label(forRawIdentifier: "call_def"),
            ],
            "a call opening is the hook's job; only its output ends anything here"
        )
    }

    /// A Codex shell command is not a tool call: it is an item inside `item_completed` with
    /// its own identifier. Measured against the app's event log, the `call_id` rule alone
    /// matched none of 56 shell calls, which is what sent me looking for this record.
    func testACodexShellCommandEndsThroughItsCompletedItem() throws {
        let increment = try read(
            [
                """
                {"type":"event_msg","timestamp":"2026-09-05T02:09:56Z","payload":{"type":"item_completed",                "item":{"type":"CommandExecution","id":"item_abc","client_id":"c"}}}
                """
            ],
            source: .codex
        )

        XCTAssertEqual(
            increment.facts,
            [
                .callReturned(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: "item_abc"),
                    at: Date(timeIntervalSince1970: 1_788_574_196)
                )
            ]
        )
    }

    // MARK: - Reading a file that is being written

    func testAHalfWrittenLastLineIsLeftForTheNextRead() throws {
        let complete = """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(rawToolUseID)"}]}}

            """
        let fragment = "{\"type\":\"user\",\"mess"
        let data = try XCTUnwrap((complete + fragment).data(using: .utf8))

        let increment = try TranscriptReader.read(increment: data, source: .claude, observedAt: now)

        XCTAssertEqual(increment.facts.count, 1)
        XCTAssertEqual(
            increment.consumedByteCount,
            complete.utf8.count,
            "the fragment is the same line arriving later, not a line to skip"
        )
    }

    /// The format is undocumented and has changed before. One unfamiliar line must not take
    /// the whole session's monitoring down, and it must not be read again forever either.
    func testAnUnreadableLineIsSkippedButStillConsumed() throws {
        let increment = try read([
            "not json at all",
            """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(rawToolUseID)"}]}}
            """,
        ])

        XCTAssertEqual(increment.facts.count, 1)
        XCTAssertGreaterThan(increment.consumedByteCount, 0)
    }

    func testAnEmptyLineStillMovesTheOffset() throws {
        let data = try XCTUnwrap("\n\n\n".data(using: .utf8))

        let increment = try TranscriptReader.read(increment: data, source: .claude, observedAt: now)

        XCTAssertTrue(increment.facts.isEmpty)
        XCTAssertEqual(increment.consumedByteCount, 3, "or the same bytes are re-read on every tick")
    }

    /// Normal growth between reads is 25–50 KB. Anything at this scale means the offset is
    /// wrong, and parsing megabytes to discover that would block the main thread for nothing.
    func testAnImplausiblyLargeIncrementIsRefusedRatherThanParsed() throws {
        let data = Data(repeating: UInt8(ascii: "\n"), count: TranscriptReader.maximumIncrementByteCount + 1)

        XCTAssertThrowsError(try TranscriptReader.read(increment: data, source: .claude, observedAt: now)) { error in
            XCTAssertEqual(
                error as? TranscriptReadError,
                .incrementTooLarge(actualByteCount: TranscriptReader.maximumIncrementByteCount + 1)
            )
        }
    }

    func testARecordWithNoTimestampIsDatedByTheRead() throws {
        let increment = try read([
            """
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\(rawToolUseID)"}]}}
            """
        ])

        XCTAssertEqual(
            increment.facts.first, .callReturned(activityID: increment.facts.first!.endedActivityID!, at: now))
    }

    /// Most of a transcript is prompts, command output and file contents. The reader walks
    /// past all of it by shape, and this is the check that it keeps doing so.
    func testRecordsTheReaderHasNoBusinessWithProduceNothing() throws {
        let increment = try read([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a long answer"}]}}"#,
            #"{"type":"ai-title","aiTitle":"Something the model named the session","sessionId":"s"}"#,
            #"{"type":"file-history-snapshot","messageId":"m"}"#,
            #"{"type":"system","subtype":"turn_duration","stopReason":""}"#,
        ])

        XCTAssertTrue(increment.facts.isEmpty)
        XCTAssertGreaterThan(increment.consumedByteCount, 0)
    }

    // MARK: - What a session says about itself

    /// The one signal both agents write, which is what lets it be the same line in either row.
    func testClaudeNamesItsModelOnEveryAssistantRecord() throws {
        let increment = try read([
            """
            {"type":"assistant","timestamp":"2026-09-05T02:09:56.557Z","message":{"role":"assistant",\
            "model":"claude-opus-5","content":[{"type":"text","text":"an answer"}]}}
            """
        ])

        XCTAssertEqual(increment.signals.modelName, "claude-opus-5")
        XCTAssertTrue(increment.facts.isEmpty, "naming a model is not something happening")
    }

    func testCodexNamesItsModelAndEffortOnEveryTurn() throws {
        let increment = try read(
            [
                """
                {"type":"turn_context","timestamp":"2026-09-05T02:09:56.557Z","payload":{"turn_id":"t",\
                "cwd":"/somewhere","model":"gpt-5.6-terra","effort":"high","approval_policy":"never"}}
                """
            ],
            source: .codex
        )

        XCTAssertEqual(increment.signals.modelName, "gpt-5.6-terra")
        XCTAssertEqual(increment.signals.reasoningEffort, "high")
    }

    /// The record carries two counts and only one of them is a context size. `total` sums
    /// every turn of the session — measured at 3.6 million against a window of 258 400, which
    /// would have been shown as 1398% — while `last` is what the model was actually holding.
    func testTheContextSizeIsTheTurnsOwnCountAndNotTheRunningTotal() throws {
        let increment = try read(
            [
                """
                {"type":"event_msg","timestamp":"2026-09-05T02:09:56.557Z","payload":{"type":"token_count",\
                "info":{"total_token_usage":{"input_tokens":3612721,"total_tokens":3700000},\
                "last_token_usage":{"input_tokens":124247,"cached_input_tokens":120000},\
                "model_context_window":258400}}}
                """
            ],
            source: .codex
        )

        XCTAssertEqual(increment.signals.contextInputTokens, 124_247)
        XCTAssertEqual(increment.signals.contextWindowTokens, 258_400)
    }

    /// A transcript is a file on disk that anything can write to, and these numbers reach a
    /// row where they decide its width.
    func testACountNoContextCouldHoldIsNotACount() throws {
        let increment = try read(
            [
                """
                {"type":"event_msg","payload":{"type":"token_count","info":{\
                "last_token_usage":{"input_tokens":1e30},"model_context_window":-5}}}
                """
            ],
            source: .codex
        )

        XCTAssertNil(increment.signals.contextInputTokens)
        XCTAssertNil(increment.signals.contextWindowTokens)
    }

    // MARK: - The opening record

    /// Stated once at the top of the file and never repeated, which is why no amount of
    /// tailing will ever find it.
    func testTheOpeningRecordSaysTheBranchAndWhoseThreadItIs() throws {
        let head = try opening(
            """
            {"type":"session_meta","timestamp":"2026-09-03T20:38:04.750Z","payload":{"session_id":"s",\
            "cwd":"/somewhere","thread_source":"subagent","agent_nickname":"Darwin",\
            "git":{"branch":"survey-foundation","commit_hash":"abc"}}}
            """
        )

        XCTAssertEqual(head.gitBranch, "survey-foundation")
        XCTAssertEqual(head.threadKind, .subagent)
        XCTAssertEqual(head.threadNickname, "Darwin")
    }

    func testAPersonsOwnThreadSaysSoAndAReviewThreadSaysThat() throws {
        XCTAssertEqual(
            try opening(#"{"type":"session_meta","payload":{"thread_source":"user"}}"#).threadKind,
            .user
        )
        XCTAssertEqual(
            try opening(#"{"type":"session_meta","payload":{"thread_source":"guardian_review"}}"#).threadKind,
            .review
        )
    }

    /// The vocabulary is undocumented and will grow. Rounding an unfamiliar kind to the
    /// nearest one this app knows would state something nobody said.
    func testAnUnfamiliarThreadKindIsNotGuessedAt() throws {
        XCTAssertNil(try opening(#"{"type":"session_meta","payload":{"thread_source":"something_new"}}"#).threadKind)
    }

    /// Claude's branch reaches the app through the hook sender, which reads the same records.
    /// Reading it here as well would put two writers on one field.
    func testAClaudeOpeningIsLeftToTheHookSender() throws {
        let head = TranscriptReader.readOpening(
            try XCTUnwrap(#"{"type":"session_meta","payload":{"git":{"branch":"main"}}}"#.data(using: .utf8)),
            source: .claude
        )

        XCTAssertTrue(head.isEmpty)
    }

    /// A head that says nothing costs these values and nothing else. The lifecycle facts come
    /// from the other end of the file, and they are why the reader exists at all.
    func testAnOpeningWithNoRecordOfItsOwnIsSimplyEmpty() throws {
        XCTAssertTrue(try opening(#"{"type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#).isEmpty)
        XCTAssertTrue(TranscriptReader.readOpening(Data(), source: .codex).isEmpty)
    }

    private func opening(_ line: String) throws -> TranscriptSignals {
        TranscriptReader.readOpening(try XCTUnwrap("\(line)\n".data(using: .utf8)), source: .codex)
    }
}

extension TranscriptFact {
    /// The activity a fact ends, for tests that care which one rather than which case.
    fileprivate var endedActivityID: String? {
        switch self {
        case let .callReturned(id, _), let .workEnded(id, _): id
        case .callStarted, .turnInterrupted: nil
        }
    }
}
