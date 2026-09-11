import Foundation
import XCTest

@testable import AgentWatchCore

/// Covers the engine operations that end or retire a session, plus the arrival index that
/// fixes where each session sits in the list.
final class SessionLifecycleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000)

    // MARK: - Arrival order

    func testConcurrentSessionsArriveInTheOrderTheyWereSeen() throws {
        var engine = SessionStateEngine()

        let first = try engine.ingest(sessionStart(id: "alpha"))
        let second = try engine.ingest(sessionStart(id: "beta"))

        XCTAssertEqual(first.arrivalIndex, 0)
        XCTAssertEqual(second.arrivalIndex, 1)
    }

    /// A reused index would drop the newcomer into the departed session's place, halfway up
    /// a list the reader had already learned. The index is what keeps rows still, so it only
    /// ever moves forward.
    func testANewSessionNeverTakesADepartedSessionsPlace() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        try engine.ingest(sessionStart(id: "beta"))

        engine.removeSession(id: "claude:alpha")
        let third = try engine.ingest(sessionStart(id: "gamma"))

        XCTAssertEqual(third.arrivalIndex, 2)
    }

    func testTheArrivalIndexSurvivesLaterEventsInTheSameSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        try engine.ingest(sessionStart(id: "beta"))

        let updated = try engine.ingest(
            envelope(id: "beta", kind: .turnStarted, at: start.addingTimeInterval(5))
        )

        XCTAssertEqual(updated.arrivalIndex, 1)
    }

    // MARK: - Session end

    func testSessionEndClosesTheSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        try engine.ingest(envelope(id: "alpha", kind: .turnStarted, at: start.addingTimeInterval(1)))

        let closed = try engine.ingest(
            envelope(id: "alpha", kind: .sessionEnded, at: start.addingTimeInterval(2))
        )

        XCTAssertEqual(closed.phase, .sessionClosed)
        XCTAssertTrue(closed.activities.isEmpty)
    }

    func testSessionEndNormalizesFromTheHookName() throws {
        let event = try HookEventNormalizer.normalize(
            source: .codex,
            declaredEvent: "SessionEnd",
            payload: .object(["session_id": .string("id_alpha")]),
            observedAt: start
        )

        XCTAssertEqual(event.kind, .sessionEnded)
    }

    // MARK: - Codex desktop termination

    func testQuittingTheDesktopAppClosesOnlyItsOwnSessions() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "desktop", source: .codex, clientKind: .desktop))
        try engine.ingest(sessionStart(id: "cli", source: .codex, clientKind: .cli))
        try engine.ingest(sessionStart(id: "claude", source: .claude, clientKind: .cli))

        let closed = engine.markDesktopSessionsClosed(source: .codex, at: start.addingTimeInterval(10))

        XCTAssertEqual(closed.map(\.id), ["codex:desktop"])
        XCTAssertEqual(engine.snapshots["codex:desktop"]?.phase, .sessionClosed)
        XCTAssertEqual(engine.snapshots["codex:cli"]?.phase, .idle)
        XCTAssertEqual(engine.snapshots["claude:claude"]?.phase, .idle)
    }

    func testQuittingTheDesktopAppTwiceReportsNothingTheSecondTime() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "desktop", source: .codex, clientKind: .desktop))

        engine.markDesktopSessionsClosed(source: .codex, at: start.addingTimeInterval(10))
        let second = engine.markDesktopSessionsClosed(source: .codex, at: start.addingTimeInterval(20))

        XCTAssertTrue(second.isEmpty)
    }

    // MARK: - Loss of signal

    func testOnlyUnwatchedSessionsFallBackToDisconnected() throws {
        var engine = SessionStateEngine()
        try engine.ingest(working(id: "watched-pid", source: .claude, agentProcessID: 4_242))
        try engine.ingest(working(id: "watched-app", source: .codex, clientKind: .desktop))
        try engine.ingest(working(id: "unwatched", source: .codex, clientKind: .cli))

        let disconnected = engine.markUnwatchedSessionsDisconnected(
            now: start.addingTimeInterval(1_000),
            after: 900,
            watchedSessionIDs: ["claude:watched-pid", "codex:watched-app"]
        )

        XCTAssertEqual(disconnected.map(\.id), ["codex:unwatched"])
        XCTAssertEqual(engine.snapshots["claude:watched-pid"]?.phase, .executing)
        XCTAssertEqual(engine.snapshots["codex:watched-app"]?.phase, .executing)
    }

    func testAPIDAloneDoesNotCountAsAWatchTheEngineInvented() throws {
        var engine = SessionStateEngine()
        try engine.ingest(working(id: "has-pid", source: .codex, clientKind: .cli, agentProcessID: 4_242))

        let disconnected = engine.markUnwatchedSessionsDisconnected(
            now: start.addingTimeInterval(1_000),
            after: 900,
            watchedSessionIDs: []
        )

        XCTAssertEqual(
            disconnected.map(\.id),
            ["codex:has-pid"],
            "only the caller knows which sessions are actually watched; a PID is not proof"
        )
    }

    func testANonPositiveThresholdDemotesNothing() throws {
        var engine = SessionStateEngine()
        try engine.ingest(working(id: "unwatched", source: .codex, clientKind: .cli))

        XCTAssertTrue(
            engine.markUnwatchedSessionsDisconnected(
                now: start.addingTimeInterval(10_000),
                after: 0,
                watchedSessionIDs: []
            ).isEmpty
        )
    }

    func testDisconnectDoesNotPretendSomethingWasObserved() throws {
        var engine = SessionStateEngine()
        let observedAt = start.addingTimeInterval(1)
        try engine.ingest(working(id: "unwatched", source: .codex, clientKind: .cli, at: observedAt))

        engine.markUnwatchedSessionsDisconnected(
            now: start.addingTimeInterval(1_000),
            after: 900,
            watchedSessionIDs: []
        )

        XCTAssertEqual(engine.snapshots["codex:unwatched"]?.lastObservedAt, observedAt)
    }

    func testASessionStillWithinTheThresholdKeepsItsPhase() throws {
        var engine = SessionStateEngine()
        try engine.ingest(working(id: "unwatched", source: .codex, clientKind: .cli))

        let disconnected = engine.markUnwatchedSessionsDisconnected(
            now: start.addingTimeInterval(100),
            after: 900,
            watchedSessionIDs: []
        )

        XCTAssertTrue(disconnected.isEmpty)
        XCTAssertEqual(engine.snapshots["codex:unwatched"]?.phase, .executing)
    }

    func testANewEventBringsADisconnectedSessionBack() throws {
        var engine = SessionStateEngine()
        try engine.ingest(working(id: "unwatched", source: .codex, clientKind: .cli))
        engine.markUnwatchedSessionsDisconnected(
            now: start.addingTimeInterval(1_000),
            after: 900,
            watchedSessionIDs: []
        )

        let resumed = try engine.ingest(
            envelope(id: "unwatched", source: .codex, kind: .turnStarted, at: start.addingTimeInterval(1_001))
        )

        XCTAssertEqual(resumed.phase, .executing)
    }

    func testWaitingForUserIsNeverDemotedToDisconnected() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "unwatched", source: .codex, clientKind: .cli))
        try engine.ingest(
            envelope(id: "unwatched", source: .codex, kind: .userInputRequired, at: start.addingTimeInterval(1))
        )

        let disconnected = engine.markUnwatchedSessionsDisconnected(
            now: start.addingTimeInterval(10_000),
            after: 900,
            watchedSessionIDs: []
        )

        XCTAssertTrue(disconnected.isEmpty, "a session waiting on a person has not lost its signal")
    }

    // MARK: - Retiring closed sessions

    func testAClosedSessionIsRetiredOnceItsRetentionElapses() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        engine.markSessionClosed(id: "claude:alpha", at: start.addingTimeInterval(10))

        let removed = engine.removeExpiredClosedSessions(now: start.addingTimeInterval(131), retention: 120)

        XCTAssertEqual(removed, ["claude:alpha"])
        XCTAssertTrue(engine.snapshots.isEmpty)
    }

    func testAClosedSessionStaysVisibleUntilItsRetentionElapses() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        engine.markSessionClosed(id: "claude:alpha", at: start.addingTimeInterval(10))

        let removed = engine.removeExpiredClosedSessions(now: start.addingTimeInterval(100), retention: 120)

        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(engine.snapshots["claude:alpha"]?.phase, .sessionClosed)
    }

    func testAnOpenSessionIsNeverRetired() throws {
        var engine = SessionStateEngine()
        try engine.ingest(working(id: "alpha"))

        let removed = engine.removeExpiredClosedSessions(now: start.addingTimeInterval(10_000), retention: 120)

        XCTAssertTrue(removed.isEmpty)
    }

    // MARK: - The session mode

    /// `docs/implementation-plan.md`: a missing `permission_mode` means the mode is unknown
    /// and is never guessed. Guessing `standard` turned a session that had started in plan
    /// mode into a working one the moment its next prompt arrived without one.
    func testATurnWithoutADeclaredModeKeepsTheOneAlreadyKnown() throws {
        var engine = SessionStateEngine()
        try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "alpha",
                observedAt: start,
                kind: .turnStarted,
                mode: .plan
            )
        )

        let next = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "alpha",
                observedAt: start.addingTimeInterval(1),
                kind: .turnStarted
            )
        )

        XCTAssertEqual(next.mode, .plan)
        XCTAssertEqual(next.phase, .planning)
    }

    /// And a mode that is actually stated still wins, in both directions.
    func testADeclaredModeAlwaysReplacesTheOneBefore() throws {
        var engine = SessionStateEngine()
        try engine.ingest(
            EventEnvelope(source: .claude, sessionID: "alpha", observedAt: start, kind: .turnStarted, mode: .plan)
        )

        let left = try engine.ingest(
            EventEnvelope(
                source: .claude,
                sessionID: "alpha",
                observedAt: start.addingTimeInterval(1),
                kind: .turnStarted,
                mode: .standard
            )
        )

        XCTAssertEqual(left.mode, .standard)
        XCTAssertEqual(left.phase, .executing)
    }

    // MARK: - A closed session stays closed

    /// The state diagram in `docs/architecture.md` §7 has no edge leaving `SessionClosed`,
    /// and the protocol is required to survive events arriving out of order — so a `Stop`
    /// landing after a `SessionEnd` must not put the session back to work.
    func testALateEventCannotReopenAClosedSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        try engine.ingest(envelope(id: "alpha", kind: .sessionEnded, at: start.addingTimeInterval(5)))

        let late = try engine.ingest(
            envelope(id: "alpha", kind: .turnCompleted, at: start.addingTimeInterval(4))
        )

        XCTAssertEqual(late.phase, .sessionClosed)
        XCTAssertEqual(late.lastObservedAt, start.addingTimeInterval(5), "and the clock does not move back")
    }

    /// What a late event still says about the session is kept; only its lifecycle meaning
    /// is dropped.
    func testALateEventStillCarriesWhatItKnowsAboutAClosedSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        try engine.ingest(envelope(id: "alpha", kind: .sessionEnded, at: start.addingTimeInterval(5)))

        let late = try engine.ingest(
            envelope(
                id: "alpha",
                kind: .turnStarted,
                at: start.addingTimeInterval(4),
                description: .init(title: "Позднее имя", gitBranch: "main")
            )
        )

        XCTAssertEqual(late.phase, .sessionClosed)
        XCTAssertEqual(late.title, "Позднее имя")
        XCTAssertEqual(late.gitBranch, "main")
    }

    /// The identifier really is reused when a session is cleared and started again, and that
    /// is a new session's first event rather than a late one from the old.
    func testASessionStartStillReopensAClosedSession() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        try engine.ingest(envelope(id: "alpha", kind: .sessionEnded, at: start.addingTimeInterval(5)))

        let reopened = try engine.ingest(
            envelope(id: "alpha", kind: .sessionStarted, at: start.addingTimeInterval(6))
        )

        XCTAssertEqual(reopened.phase, .idle)
    }

    /// `/clear` is not a new session to Codex — the identifier is reused, which the engine
    /// already relies on to reopen a closed one. The only thing that says the conversation was
    /// thrown away is a `SessionStart` arriving at a session that was in the middle of
    /// something, and the reset a session start already performs *is* the reaction: no new
    /// event, and no need to read the `source` field that distinguishes clear from startup.
    ///
    /// What was missing is this test. The one that reopens a session covers a start after
    /// `sessionEnded`, and a session holding a running tool call is a different state: there
    /// the risk is not "does it come back" but "does the work it was doing come back with it".
    func testAStartArrivingMidWorkThrowsAwayWhatTheTurnWasDoing() throws {
        var engine = SessionStateEngine()
        let session: JSONValue = .object(["session_id": .string("id_session")])
        for event in ["SessionStart", "UserPromptSubmit"] {
            try engine.ingest(
                HookEventNormalizer.normalize(
                    source: .codex, declaredEvent: event, payload: session, observedAt: start))
        }
        let working = try engine.ingest(
            HookEventNormalizer.normalize(
                source: .codex,
                declaredEvent: "PreToolUse",
                payload: .object([
                    "session_id": .string("id_session"),
                    "tool_use_id": .string("id_call"),
                    "tool_name": .string("Bash"),
                ]),
                observedAt: start.addingTimeInterval(1)
            ))
        XCTAssertEqual(working.phase, .executing)
        XCTAssertEqual(working.activities.count, 1)

        let cleared = try engine.ingest(
            HookEventNormalizer.normalize(
                source: .codex,
                declaredEvent: "SessionStart",
                payload: .object(["session_id": .string("id_session"), "source": .string("clear")]),
                observedAt: start.addingTimeInterval(2)
            ))

        XCTAssertEqual(cleared.phase, .idle)
        XCTAssertTrue(cleared.activities.isEmpty, "a cleared conversation is not still running a call")
    }

    /// A second death signal must not restart the retention clock that is about to retire it.
    func testClosingAnAlreadyClosedSessionChangesNothing() throws {
        var engine = SessionStateEngine()
        try engine.ingest(sessionStart(id: "alpha"))
        let closed = try XCTUnwrap(engine.markSessionClosed(id: "claude:alpha", at: start.addingTimeInterval(5)))

        XCTAssertNil(engine.markSessionClosed(id: "claude:alpha", at: start.addingTimeInterval(60)))
        XCTAssertEqual(engine.snapshots["claude:alpha"]?.lastObservedAt, closed.lastObservedAt)
    }

    // MARK: - Session title

    func testTheAgentsOwnTitleReplacesTheSourceName() throws {
        var engine = SessionStateEngine()

        let snapshot = try engine.ingest(
            envelope(id: "alpha", kind: .sessionStarted, at: start, description: .init(title: "AGENTS.md в CLAUDE.md"))
        )

        XCTAssertEqual(snapshot.title, "AGENTS.md в CLAUDE.md")
    }

    func testAnEventWithoutATitleKeepsTheOneAlreadyKnown() throws {
        var engine = SessionStateEngine()
        try engine.ingest(
            envelope(id: "alpha", kind: .sessionStarted, at: start, description: .init(title: "Первый заголовок")))

        let later = try engine.ingest(
            envelope(id: "alpha", kind: .activityCompleted, at: start.addingTimeInterval(1))
        )

        XCTAssertEqual(later.title, "Первый заголовок")
    }

    /// A session nobody has named has no name. The engine used to fill one in from the
    /// product — "Claude Code" — which the row then printed beside the Claude icon, saying
    /// the same thing twice, and the hover card repeated it on two consecutive lines.
    func testASessionNobodyHasNamedHasNoName() throws {
        var engine = SessionStateEngine()

        let claude = try engine.ingest(sessionStart(id: "alpha", source: .claude))
        let codex = try engine.ingest(sessionStart(id: "beta", source: .codex))

        XCTAssertNil(claude.title)
        XCTAssertNil(codex.title)
    }

    func testATitleIsCappedAndStrippedOfControlCharacters() {
        let cap = HookIngressRequest.maximumSessionTitleLength
        XCTAssertEqual(HookIngressRequest.sanitizedText("линия\nвторая\tтретья", limit: cap), "линия вторая третья")
        XCTAssertEqual(HookIngressRequest.sanitizedText(String(repeating: "я", count: 400), limit: cap)?.count, cap)
        XCTAssertEqual(HookIngressRequest.sanitizedText(String(repeating: "я", count: cap), limit: cap)?.count, cap)
        XCTAssertNil(HookIngressRequest.sanitizedText("   ", limit: cap))
        XCTAssertNil(HookIngressRequest.sanitizedText(nil, limit: cap))
        XCTAssertNil(HookIngressRequest.sanitizedText("\u{0}\u{1}\u{7}", limit: cap))
    }

    /// A directory name and a branch name are short by nature, and they get a tighter cap
    /// than the title. A token count that arrives as zero or negative is not a count.
    func testTheOtherDescribedFieldsAreCappedAndChecked() throws {
        let sanitized = try XCTUnwrap(
            HookIngressRequest.sanitized(
                SessionDescription(
                    title: "Заголовок",
                    projectName: String(repeating: "п", count: 200),
                    gitBranch: "feature/\nветка",
                    contextInputTokens: 0
                )
            )
        )

        XCTAssertEqual(sanitized.projectName?.count, HookIngressRequest.maximumShortFieldLength)
        XCTAssertEqual(sanitized.gitBranch, "feature/ ветка")
        XCTAssertNil(sanitized.contextInputTokens)
        XCTAssertNil(HookIngressRequest.sanitized(SessionDescription()), "nothing known is not a description")
    }

    /// `docs/architecture.md` §15 promises the app never receives a path. This field skips
    /// the redactor entirely — it travels beside the payload, not inside it — so the promise
    /// is kept here or nowhere.
    func testAProjectNameThatIsActuallyAPathIsRefused() {
        let described = HookIngressRequest.sanitized(
            SessionDescription(title: "Заголовок", projectName: "/Users/name/CommonProjects/agent-watch")
        )

        XCTAssertNil(described?.projectName)
        XCTAssertEqual(described?.title, "Заголовок", "the rest of the description still stands")
        XCTAssertEqual(
            HookIngressRequest.sanitized(SessionDescription(projectName: "agent-watch"))?.projectName,
            "agent-watch"
        )
    }

    /// The count is what a row's width is measured against, so an unbounded one would stretch
    /// a row past the widget it was measured for.
    func testAnImpossibleTokenCountIsRefused() {
        let cap = SessionDescription.maximumContextInputTokens

        XCTAssertNil(HookIngressRequest.sanitized(SessionDescription(contextInputTokens: .max))?.contextInputTokens)
        XCTAssertNil(HookIngressRequest.sanitized(SessionDescription(contextInputTokens: cap + 1))?.contextInputTokens)
        XCTAssertEqual(
            HookIngressRequest.sanitized(SessionDescription(contextInputTokens: cap))?.contextInputTokens,
            cap
        )
    }

    /// A right-to-left override makes a label read backwards, which is the one thing this
    /// sanitiser exists to prevent. The zero-width joiner is a format character too and has
    /// to survive, or a composed emoji falls apart.
    func testTextThatWouldReverseItsOwnReadingOrderIsStripped() {
        let cap = HookIngressRequest.maximumSessionTitleLength
        let reversed = "\u{202E}gnp.exe"

        XCTAssertEqual(HookIngressRequest.sanitizedText(reversed, limit: cap), "gnp.exe")
        XCTAssertEqual(HookIngressRequest.sanitizedText("a\u{2066}b\u{2069}c", limit: cap), "a b c")
        XCTAssertEqual(HookIngressRequest.sanitizedText("👨‍👩‍👧", limit: cap)?.count, 1)
    }

    /// A percentage arrives from a provider that measured it with its own token count. Shown
    /// beside a count read later from a transcript, it would read as one measurement.
    func testATranscriptTokenCountDoesNotInheritAnEarlierPercentage() throws {
        var engine = SessionStateEngine()
        try engine.ingest(
            envelope(
                id: "alpha",
                kind: .statusUpdated,
                at: start,
                contextTelemetry: SessionContextTelemetry(totalInputTokens: 85_000, usedPercentage: 42.5)
            )
        )

        let later = try engine.ingest(
            envelope(
                id: "alpha",
                kind: .activityCompleted,
                at: start.addingTimeInterval(1),
                description: .init(contextInputTokens: 30_000)
            )
        )

        XCTAssertEqual(later.contextTelemetry?.totalInputTokens, 30_000)
        XCTAssertNil(later.contextTelemetry?.usedPercentage, "the old percentage measured a different count")
    }

    /// The socket decodes `HookIngressRequest` with a synthesized `Decodable`, which never
    /// runs the memberwise initialiser. Sanitising there would therefore have applied only
    /// to data the app built itself. This asserts the cap on the path bytes actually take.
    func testATitleArrivingAsJSONIsSanitisedAtTheTrustBoundary() throws {
        let hostile = String(repeating: "я", count: 400) + "\nвторая строка"
        let json = try JSONEncoder().encode(
            HookIngressRequest(
                source: .claude,
                declaredEvent: "SessionStart",
                payload: .object(["session_id": .string("id_alpha")]),
                description: .init(title: hostile)
            )
        )
        let decoded = try JSONDecoder().decode(HookIngressRequest.self, from: json)
        XCTAssertEqual(decoded.description?.title, hostile, "the decoder is a plain DTO and does not rewrite values")

        let event = try HookIngressProcessor.normalize(decoded, observedAt: start)

        XCTAssertEqual(event.description?.title?.count, 120)
        XCTAssertFalse(event.description?.title?.contains("\n") ?? true)
    }

    func testAComposedEmojiInATitleSurvivesSanitising() {
        // The zero-width joiner is a format character, not a control character. Stripping
        // it would split one family emoji into three separate people.
        let family = "👨‍👩‍👧"

        let cap = HookIngressRequest.maximumSessionTitleLength
        XCTAssertEqual(HookIngressRequest.sanitizedText("Ветка \(family)", limit: cap), "Ветка \(family)")
        XCTAssertEqual(HookIngressRequest.sanitizedText(family, limit: cap)?.count, 1)
    }

    // MARK: - A process that moved on to another session

    /// Measured on a real machine: starting `claude` and then resuming an earlier
    /// conversation is two sessions in one process. The first one lives about two seconds —
    /// long enough to send a start and an end — and the row it left behind sat on the widget
    /// with no name and nothing to say until the retention ran out.
    func testAClosedSessionLeavesWhenItsProcessTurnsOutToRunAnother() throws {
        var engine = SessionStateEngine()
        try engine.ingest(envelope(id: "throwaway", kind: .sessionStarted, at: start, agentProcessID: 501))
        try engine.ingest(
            envelope(id: "throwaway", kind: .sessionEnded, at: start.addingTimeInterval(2), agentProcessID: 501)
        )

        let resumed = envelope(
            id: "resumed",
            kind: .sessionStarted,
            at: start.addingTimeInterval(2),
            agentProcessID: 501
        )
        let retired = engine.retireSessionsSuperseded(by: resumed)
        try engine.ingest(resumed)

        XCTAssertEqual(retired.map(\.id), ["claude:throwaway"])
        XCTAssertNil(engine.snapshots["claude:throwaway"])
        XCTAssertNotNil(engine.snapshots["claude:resumed"])
    }

    /// The resumed session keeps its own identifier, so the row it comes back to is its own
    /// — the one thing this rule must never take away.
    func testAResumedSessionKeepsTheRowItIsComingBackTo() throws {
        var engine = SessionStateEngine()
        try engine.ingest(envelope(id: "alpha", kind: .sessionStarted, at: start, agentProcessID: 501))
        try engine.ingest(
            envelope(id: "alpha", kind: .sessionEnded, at: start.addingTimeInterval(60), agentProcessID: 501)
        )

        let resumed = envelope(
            id: "alpha",
            kind: .sessionStarted,
            at: start.addingTimeInterval(120),
            agentProcessID: 502
        )
        XCTAssertEqual(engine.retireSessionsSuperseded(by: resumed), [])
        let revived = try engine.ingest(resumed)

        XCTAssertEqual(revived.phase, .idle)
        XCTAssertEqual(revived.arrivalIndex, 0, "the row a person was looking at stays where it was")
    }

    /// Events arrive out of order, and a late start from a session that once held this
    /// process number must not take away the row of the session running on it now.
    func testALiveSessionIsNeverRetiredByAnotherOnItsProcess() throws {
        var engine = SessionStateEngine()
        try engine.ingest(envelope(id: "alpha", kind: .sessionStarted, at: start, agentProcessID: 501))

        let other = envelope(
            id: "beta",
            kind: .sessionStarted,
            at: start.addingTimeInterval(1),
            agentProcessID: 501
        )

        XCTAssertEqual(engine.retireSessionsSuperseded(by: other), [])
        XCTAssertNotNil(engine.snapshots["claude:alpha"])
    }

    /// Codex reports no process number at all, so nothing it sends can retire anything.
    func testAnEventWithNoProcessNumberRetiresNothing() throws {
        var engine = SessionStateEngine()
        try engine.ingest(envelope(id: "alpha", kind: .sessionStarted, at: start, agentProcessID: 501))
        try engine.ingest(
            envelope(id: "alpha", kind: .sessionEnded, at: start.addingTimeInterval(2), agentProcessID: 501)
        )

        let anonymous = envelope(id: "beta", kind: .sessionStarted, at: start.addingTimeInterval(3))

        XCTAssertEqual(engine.retireSessionsSuperseded(by: anonymous), [])
        XCTAssertNotNil(engine.snapshots["claude:alpha"])
    }

    // MARK: - Helpers

    private func sessionStart(
        id: String,
        source: AgentSource = .claude,
        clientKind: SessionClientKind? = nil
    ) -> EventEnvelope {
        envelope(id: id, source: source, kind: .sessionStarted, at: start, clientKind: clientKind)
    }

    private func working(
        id: String,
        source: AgentSource = .claude,
        clientKind: SessionClientKind? = nil,
        agentProcessID: Int32? = nil,
        at observedAt: Date? = nil
    ) -> EventEnvelope {
        envelope(
            id: id,
            source: source,
            kind: .turnStarted,
            at: observedAt ?? start,
            clientKind: clientKind,
            agentProcessID: agentProcessID
        )
    }

    private func envelope(
        id: String,
        source: AgentSource = .claude,
        kind: EventKind,
        at observedAt: Date,
        clientKind: SessionClientKind? = nil,
        agentProcessID: Int32? = nil,
        description: SessionDescription? = nil,
        contextTelemetry: SessionContextTelemetry? = nil
    ) -> EventEnvelope {
        EventEnvelope(
            source: source,
            sessionID: id,
            description: description,
            activityID: kind == .activityCompleted ? "activity-1" : nil,
            observedAt: observedAt,
            kind: kind,
            mode: .standard,
            userInputRequestKind: kind == .userInputRequired ? .approval : nil,
            agentProcessID: agentProcessID,
            clientKind: clientKind,
            contextTelemetry: contextTelemetry
        )
    }
}
