import AgentWatchCore
import XCTest

/// The address a desktop client answers with one of its sessions, and what may go into it.
/// Measured on Claude.app 2.26454.0 and ChatGPT.app 26.1002.52244 —
/// `docs/session-focus-research.md`, «Десктопные клиенты».
final class DesktopSessionLinkTests: XCTestCase {
    /// The record of a process Claude.app started, as Claude Code 2.1.289 wrote it.
    func testARecordClaudeAppWroteNamesTheSessionInsideTheApp() throws {
        let record = try XCTUnwrap(
            ClaudeSessionRecord(
                data: Data(
                    #"""
                    {"pid":8864,"sessionId":"b328413e-5219-4a09-a31d-fa7339d39d6e",
                     "procStart":"Wed Oct  7 17:43:39 2026","kind":"interactive",
                     "entrypoint":"claude-desktop","hostSessionId":"local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8"}
                    """#.utf8)))

        XCTAssertTrue(record.isDesktopSession)
        XCTAssertEqual(record.desktopSessionID, "local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8")
    }

    /// A terminal session's record has no host of its own, and a host other than Claude.app
    /// would name the session in a scheme Claude.app's link does not take.
    func testOnlyARecordClaudeAppWroteNamesASessionInsideIt() throws {
        let terminal = try XCTUnwrap(
            ClaudeSessionRecord(data: Data(#"{"pid":58741,"procStart":"Mon Sep 28 15:58:38 2026"}"#.utf8)))
        let elsewhere = try XCTUnwrap(
            ClaudeSessionRecord(
                data: Data(
                    #"{"pid":400,"entrypoint":"cli","hostSessionId":"local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8"}"#
                        .utf8)))

        XCTAssertFalse(terminal.isDesktopSession)
        XCTAssertNil(terminal.desktopSessionID)
        XCTAssertFalse(elsewhere.isDesktopSession)
        XCTAssertNil(elsewhere.desktopSessionID)
    }

    /// The record is of a live process, but a number handed out again may by now be another
    /// of Claude.app's sessions: only the row's own session gets the link.
    func testClaudeAppIsAskedOnlyForTheRowsOwnSession() throws {
        let record = try XCTUnwrap(
            ClaudeSessionRecord(
                data: Data(
                    #"""
                    {"pid":8864,"sessionId":"b328413e-5219-4a09-a31d-fa7339d39d6e","entrypoint":"claude-desktop",
                     "hostSessionId":"local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8"}
                    """#.utf8)))
        let own = HookCaptureRedactor.label(forRawIdentifier: "b328413e-5219-4a09-a31d-fa7339d39d6e")
        let other = HookCaptureRedactor.label(forRawIdentifier: "a9afa821-f4f2-4a6c-b65e-4535a6e5c1bb")

        XCTAssertEqual(
            DesktopSessionLink.claude(record: record, sessionLabel: own)?.absoluteString,
            "claude://code/continue?session=local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8"
        )
        XCTAssertNil(DesktopSessionLink.claude(record: record, sessionLabel: other))
    }

    func testClaudeAppIsAskedToContinueTheSession() throws {
        let link = try XCTUnwrap(
            DesktopSessionLink.claude(desktopSessionID: "local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8"))

        XCTAssertEqual(link.absoluteString, "claude://code/continue?session=local_3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8")
    }

    /// Claude.app refuses anything but `^local_[A-Za-z0-9-]{1,64}$` — after coming forward, so
    /// a link built from another shape would look like a click that worked. A value that could
    /// add a parameter of its own is the case that matters most.
    func testOnlyTheShapeClaudeAppAcceptsGoesIntoItsLink() {
        for refused in [
            "", "local_", "3f2a9c1e-8b47-4d05-a6e2-91c0d7b4e5f8", "cse_0123", "local_abc&session=last",
            "local_abc/def", "local_ab c", "local_\u{0430}bc", "local_" + String(repeating: "a", count: 65),
        ] {
            XCTAssertNil(DesktopSessionLink.claude(desktopSessionID: refused), refused)
        }
        XCTAssertNotNil(DesktopSessionLink.claude(desktopSessionID: "local_" + String(repeating: "a", count: 64)))
    }

    /// The thread is the one the transcript is named after, and only when that is the row's
    /// own session: the label is the identifier redacted twice, as the row knows it.
    func testChatGPTIsAskedForTheThreadTheTranscriptIsNamedAfter() throws {
        let thread = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
        let transcript = URL(
            fileURLWithPath: "/Users/someone/.codex/sessions/2026/10/07/rollout-2026-10-07T20-59-15-\(thread).jsonl")

        let link = try XCTUnwrap(
            DesktopSessionLink.codex(
                transcript: transcript, sessionLabel: HookCaptureRedactor.label(forRawIdentifier: thread)))

        XCTAssertEqual(link.absoluteString, "codex://threads/\(thread)")
    }

    func testATranscriptOfAnotherSessionSendsTheClickNowhere() {
        let transcript = URL(
            fileURLWithPath:
                "/Users/someone/.codex/sessions/2026/10/07/rollout-2026-10-07T20-59-15-019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b.jsonl"
        )
        let notAThread = URL(fileURLWithPath: "/Users/someone/.codex/sessions/2026/10/07/notes.jsonl")
        let someoneElse = HookCaptureRedactor.label(forRawIdentifier: "01a11136-a671-7840-bade-ed65b91cb0a9")

        XCTAssertNil(DesktopSessionLink.codex(transcript: transcript, sessionLabel: someoneElse))
        XCTAssertNil(DesktopSessionLink.codex(transcript: notAThread, sessionLabel: someoneElse))
    }
}
