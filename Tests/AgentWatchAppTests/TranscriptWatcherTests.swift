import AgentWatchCore
import AgentWatchTestSupport
import XCTest

@testable import AgentWatchApp

/// Real files in a real directory, named the way the agents name theirs. The whole mechanism
/// rests on finding a file by hashing its name, so a test that stubbed the file system would
/// be checking only the parts that were never in doubt.
@MainActor
final class TranscriptWatcherTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_788_574_197)
    /// A real session identifier, so the label the locator hashes is a real one too.
    private let sessionUUID = "bfe119e1-b5de-45e1-9035-d58c671803d0"
    private let codexSessionUUID = "01a05e55-adab-7881-abc6-b9fe09056a27"

    private var clock = Date(timeIntervalSince1970: 1_788_574_197)
    private var inbox: [TranscriptUpdate] = []
    private var arrival: XCTestExpectation?

    /// Created on first use rather than in `setUp`, which XCTest calls outside the main
    /// actor this class lives on. A test that never looks at a file never makes a directory.
    private lazy var home: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchTranscriptTests.\(UUID().uuidString)", isDirectory: true)
        for directory in [".claude/projects/-Users-someone-project", ".codex/sessions/2026/09/05"] {
            try? FileManager.default.createDirectory(
                at: url.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return url
    }()

    /// The file holds the session's whole history. Reading it from the start would close
    /// calls that ended an hour ago and would idle the session on an interruption from
    /// before the app was even launched.
    func testItReadsOnlyWhatArrivesAfterItStartsWatching() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])

        let firstPass = try await poll(watcher)
        XCTAssertTrue(firstPass.flatMap(\.facts).isEmpty, "everything already in the file is history")

        try append(toolResult(id: "call-new"))
        let secondPass = try await poll(watcher)

        XCTAssertEqual(
            secondPass.flatMap(\.facts),
            [
                .callReturned(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: "call-new"),
                    at: Date(timeIntervalSince1970: 1_788_574_196)
                )
            ]
        )
    }

    /// `/bg` continues a session in a copy that writes a transcript of its own, named after
    /// its own identifier, and the original's file stops growing. A row continued that way is
    /// read from the copy's file from the moment the row says so — and from that file's end,
    /// the way any newly found file is read, so the copy's history is not replayed.
    func testARowContinuedByACopyIsReadFromTheCopysTranscript() async throws {
        let copyUUID = "b95a16c1-8449-41f9-8487-5b3e0ad5e052"
        let copyURL = projectDirectory.appendingPathComponent("\(copyUUID).jsonl")
        try write(toolResult(id: "call-old"))
        try Data("\(toolResult(id: "copy-old"))\n".utf8).write(to: copyURL)
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        var continued = working()
        continued.continuedBy = [HookCaptureRedactor.label(forRawIdentifier: copyUUID)]
        watcher.update(sessions: [continued])
        let switched = try await poll(watcher)
        XCTAssertTrue(switched.flatMap(\.facts).isEmpty, "the copy's history is history too")

        try append(toolResult(id: "orphan"))
        let handle = try FileHandle(forWritingTo: copyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(toolResult(id: "copy-new"))\n".utf8))
        try handle.close()
        let updates = try await poll(watcher)

        XCTAssertEqual(
            updates.flatMap(\.facts),
            [
                .callReturned(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: "copy-new"),
                    at: Date(timeIntervalSince1970: 1_788_574_196)
                )
            ],
            "the copy's file is read; the original's, which nobody writes any more, is not"
        )
    }

    /// The reading happens off the main thread, and a row can be told it is continued while a
    /// read of its old file is still running. The result of that read belongs to the old
    /// watch and must not be written into the new one — or the new watch would carry the old
    /// file's address, never look for the copy's file, and read a file nobody writes.
    func testAReadInFlightWhenTheRowIsContinuedDoesNotStampTheOldFileOnTheNewWatch() async throws {
        let copyUUID = "b95a16c1-8449-41f9-8487-5b3e0ad5e052"
        let copyURL = projectDirectory.appendingPathComponent("\(copyUUID).jsonl")
        try write(toolResult(id: "call-old"))
        try Data("\(toolResult(id: "copy-old"))\n".utf8).write(to: copyURL)
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])

        // The read starts, and before it reports the row is continued by the copy.
        let reported = expectation(description: "the read in flight reported back")
        arrival = reported
        inbox = []
        watcher.poll()
        var continued = working()
        continued.continuedBy = [HookCaptureRedactor.label(forRawIdentifier: copyUUID)]
        watcher.update(sessions: [continued])
        await fulfillment(of: [reported], timeout: 2)
        arrival = nil

        _ = try await poll(watcher)
        let handle = try FileHandle(forWritingTo: copyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(toolResult(id: "copy-new"))\n".utf8))
        try handle.close()
        let updates = try await poll(watcher)

        XCTAssertEqual(
            updates.flatMap(\.facts),
            [
                .callReturned(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: "copy-new"),
                    at: Date(timeIntervalSince1970: 1_788_574_196)
                )
            ]
        )
    }

    /// An interrupted turn delivers no hook at all. This line in the file is the only record
    /// of it anywhere, which is the reason the reader exists.
    func testItPicksUpAnEndingNoHookReports() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        try append(
            """
            {"type":"user","interruptedMessageId":"message-1","timestamp":"2026-09-05T02:09:56Z","message":{"role":"user","content":\
            [{"type":"text","text":"[Request interrupted by user]"}]}}
            """
        )

        let facts = try await poll(watcher).flatMap(\.facts)
        XCTAssertEqual(facts, [.turnInterrupted(at: Date(timeIntervalSince1970: 1_788_574_196))])
    }

    func testInterruptionBetweenHookAndFirstReadIsRecoveredWithoutReplayingHistory() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        clock = start + 1
        try append(
            """
            {"type":"user","interruptedMessageId":"message-current","timestamp":"2026-09-05T02:09:59Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
            """
        )
        let updates = try await poll(watcher)
        XCTAssertEqual(updates.flatMap(\.facts), [.turnInterrupted(at: start + 2)])
        let next = try await poll(watcher)
        XCTAssertTrue(next.flatMap(\.facts).isEmpty, "the initial fact is consumed exactly once")
    }

    func testInitialReadKeepsAnIncompleteCurrentRecordForTheNextRead() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                #"{"type":"user","interruptedMessageId":"message-current","timestamp":"2026-09-05T02:09:59Z","message":{"role":"user","content":["#
                    .utf8))
        let first = try await poll(watcher)
        XCTAssertTrue(first.flatMap(\.facts).isEmpty)
        try handle.write(contentsOf: Data((#"{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8))
        try handle.close()
        let next = try await poll(watcher)
        XCTAssertEqual(next.flatMap(\.facts), [.turnInterrupted(at: start + 2)])
    }

    // MARK: - What a session says about itself

    /// Everything else here reads the tail. The branch a session started on and whose thread
    /// it is are stated once at the top of the file and never repeated, so this is the one
    /// read that goes to the other end — taken when the file is first found.
    func testTheOpeningOfACodexFileIsReadWhenTheFileIsFound() async throws {
        try writeCodex([Self.codexOpening])
        let watcher = try makeWatcher()
        watcher.update(sessions: [workingCodex()])

        let updates = try await poll(watcher)

        XCTAssertEqual(updates.first?.signals.gitBranch, "survey-foundation")
        XCTAssertEqual(updates.first?.signals.threadKind, .subagent)
        XCTAssertEqual(updates.first?.signals.threadNickname, "Darwin")
    }

    /// The context size Codex never reports through a hook, arriving in the same increment
    /// the lifecycle facts do and costing no extra reading at all.
    func testACodexTurnBringsItsModelAndTheSizeOfItsContext() async throws {
        try writeCodex([Self.codexOpening])
        let watcher = try makeWatcher()
        watcher.update(sessions: [workingCodex()])
        _ = try await poll(watcher)

        try appendCodex(Self.codexTurnContext)
        try appendCodex(Self.codexTokenCount)
        let updates = try await poll(watcher)

        XCTAssertEqual(updates.first?.signals.modelName, "gpt-5.6-terra")
        XCTAssertEqual(updates.first?.signals.reasoningEffort, "high")
        XCTAssertEqual(updates.first?.signals.contextInputTokens, 124_247)
        XCTAssertEqual(updates.first?.signals.contextWindowTokens, 258_400)
        XCTAssertEqual(
            updates.first?.signals.gitBranch,
            "survey-foundation",
            "the opening was read a poll ago and is not read again"
        )
    }

    // MARK: - Saying so when it cannot read

    /// The file appears when the agent writes its first record, which is after the hook that
    /// announced the session. Reporting straight away would flag every session at birth.
    func testASessionWithNoTranscriptIsReportedOnlyOnceItsGraceHasPassed() async throws {
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])

        let early = try await poll(watcher)
        XCTAssertNil(early.first?.fault, "a session this young has no file yet, and that is normal")

        // Past the grace, and past the back-off that keeps a hopeless scan off every tick.
        clock = start + TranscriptWatcher.locateGrace + TranscriptWatcher.locateRetryInterval
        let late = try await poll(watcher)

        XCTAssertEqual(late.first?.fault, .transcriptNotFound)
    }

    /// A re-sync is the one recovery that loses facts. Absorbing it quietly would leave the
    /// widget confidently wrong about a session it had stopped following.
    func testAnIncrementTooLargeToBeRealResynchronisesAndSaysSo() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        try append(String(repeating: "x", count: TranscriptReader.maximumIncrementByteCount))
        let updates = try await poll(watcher)

        XCTAssertEqual(updates.first?.fault, .transcriptResynchronized)
        XCTAssertTrue(updates.flatMap(\.facts).isEmpty, "megabytes are not parsed to find out they are wrong")
    }

    /// The other half of the same guard, and the one nothing tested: a file shorter than the
    /// offset already recorded for it. That is a transcript rotated or rewritten between two
    /// reads, and without the guard the reader would seek past the end of it. Recovery has to
    /// leave the offset at the new end — set it to zero and the next read replays a history
    /// whose calls ended long ago.
    func testATranscriptShorterThanTheOffsetAlreadyHeldResynchronisesToItsNewEnd() async throws {
        try write(toolResult(id: "call-old"))
        try append(toolResult(id: "call-older"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        try write(toolResult(id: "call-new"))

        let updates = try await poll(watcher)
        XCTAssertEqual(updates.first?.fault, .transcriptResynchronized)
        XCTAssertTrue(updates.flatMap(\.facts).isEmpty, "what was in between is genuinely lost")

        // The proof that the offset moved to the end rather than back to zero: the read after
        // the recovery reports the one record appended since, and not the one already there.
        try append(toolResult(id: "call-after"))
        let following = try await poll(watcher)
        XCTAssertEqual(
            following.flatMap(\.facts).count,
            1,
            "a re-sync that rewound would close calls that ended before it, all over again"
        )
    }

    /// The end of the file is where reading starts, so a file whose end cannot be found is
    /// not a file to start reading. Taking an unknown size for zero would replay the whole
    /// history — closing calls that ended an hour ago, idling the session on an interruption
    /// from before the app was launched — and it would do it exactly when the file is already
    /// behaving oddly.
    func testAFileThatCannotBeOpenedIsReportedRatherThanReadFromTheStart() async throws {
        try write(toolResult(id: "call-old"))
        try lockTranscript()
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])

        let updates = try await poll(watcher)

        XCTAssertEqual(updates.first?.fault, .transcriptUnreadable)
        XCTAssertTrue(updates.flatMap(\.facts).isEmpty, "a file that cannot be measured is not read")
    }

    /// Which step failed and what the system called it.
    ///
    /// The fault itself says only that the transcript could not be read, which is all a
    /// person can act on. This is the other half, and it goes to the log rather than to the
    /// row: one failed read books a minute of back-off, so the triangle stands for a whole
    /// minute over an event that lasted a millisecond — and every one of the three places
    /// that raise this fault used to catch the error and drop it, leaving nothing afterwards
    /// to tell a deleted file from a changed permission.
    ///
    /// Domain and code, never `localizedDescription`: that one carries the file's path, and
    /// a path is the one thing this app keeps out of its own log.
    func testAFailedReadSaysWhichStepFailedAndWhatTheSystemCalledIt() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        try lockTranscript()
        let updates = try await poll(watcher)

        XCTAssertEqual(updates.first?.fault, .transcriptUnreadable)
        let detail = try XCTUnwrap(updates.first?.faultDetail)
        // 513 rather than the 257 a reader would expect: Foundation reports a read refused
        // for permissions under its write-permission code. Left exactly as the system gives
        // it, because a number that can be looked up beats a sentence this file invented.
        XCTAssertEqual(detail, "open: NSCocoaErrorDomain 513")
        XCTAssertFalse(detail.contains(transcriptURL.path), "a path never goes into the log")
    }

    /// A file found by name and then unusable costs the same scan of the whole root as one
    /// that was never there, so it waits the same minute. Without this the back-off is
    /// bypassed: every tick drops the path, and every next tick searches again.
    func testAFileThatCannotBeReadIsNotSearchedForAgainOnTheNextTick() async throws {
        try write(toolResult(id: "call-old"))
        try lockTranscript()
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcriptURL.path)
        await pollExpectingNothing(watcher)

        clock = start + TranscriptWatcher.locateRetryInterval
        let recovered = try await poll(watcher)
        XCTAssertNil(recovered.first?.fault, "the minute is up and the file reads again")
    }

    /// While that minute runs, the session's age stands still because nobody is reading it —
    /// and that is not silence. Reporting it as silence would replace the honest complaint
    /// already on the row with a wrong one: nothing has been heard because nobody is
    /// currently listening.
    func testASessionNobodyIsReadingIsNotAlsoReportedAsSilent() async throws {
        try write(toolResult(id: "call-old"))
        try lockTranscript()
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        let failed = try await poll(watcher)
        XCTAssertEqual(failed.first?.fault, .transcriptUnreadable)

        // The back-off is shorter than the silence threshold, so the file is tried again on
        // the way there and fails again, booking another minute.
        clock = start + SessionSilence.defaultUnexplainedAfter
        let triedAgain = try await poll(watcher)
        XCTAssertEqual(triedAgain.first?.fault, .transcriptUnreadable)

        // Now past the threshold and between two attempts, which is the tick that used to
        // report silence over the top of it.
        clock = start + SessionSilence.defaultUnexplainedAfter + 5
        await pollExpectingNothing(watcher)
    }

    /// A session that claims to be working with nothing running under it, silent for
    /// minutes, is the case no other signal covers.
    func testSilenceNothingAccountsForIsReported() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        clock = start + SessionSilence.defaultUnexplainedAfter
        let updates = try await poll(watcher)

        XCTAssertEqual(updates.first?.fault, .unexplainedSilence)
    }

    /// The other half of that rule. A turn spent thinking calls nothing and delivers no hook,
    /// and writes lines like this one the whole time — so the file growing is the difference
    /// between a session nobody can hear and one nobody has anything to take from. Reported
    /// even though there is not a single fact in it.
    func testAGrowingFileIsNotASilentSession() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        _ = try await poll(watcher)

        try append(
            """
            {"type":"assistant","timestamp":"2026-09-05T02:11:00Z","message":{"role":"assistant",\
            "content":[{"type":"text","text":"still thinking about it"}]}}
            """
        )
        clock = start + SessionSilence.defaultUnexplainedAfter
        let updates = try await poll(watcher)

        XCTAssertTrue(updates.flatMap(\.facts).isEmpty, "nothing in that line is a fact")
        XCTAssertEqual(updates.first?.newestRecordAt, Date(timeIntervalSince1970: 1_788_574_260))
        XCTAssertNil(updates.first?.fault, "a file still being written to is not silence")
    }

    // MARK: - When it runs at all

    /// The sessions whose quiet might end without a hook: those claiming work, and the one
    /// waiting for a person. The wait used to be left out as quiet that explains itself — and
    /// it does, right up to the moment the person presses Esc on the dialog: measured, that
    /// writes `[Request interrupted by user for tool use]` into the transcript and fires no
    /// hook, so a row nobody read stayed at "waiting for approval" for a dialog long gone.
    func testASessionThatClaimsWorkOrWaitsForAPersonIsWorthReading() {
        let watchable = TranscriptWatcher.watchableSessions(
            [
                testSession(index: 0, phase: .executing, lastObservedAt: start),
                testSession(index: 1, phase: .planning, lastObservedAt: start),
                testSession(index: 2, phase: .waitingForChildren, lastObservedAt: start),
                testSession(index: 3, phase: .idle, lastObservedAt: start),
                testSession(index: 4, phase: .waitingForUser, lastObservedAt: start),
                testSession(index: 5, phase: .completed, lastObservedAt: start),
                testSession(index: 6, phase: .sessionClosed, lastObservedAt: start),
            ],
            now: start
        )

        XCTAssertEqual(watchable.map(\.arrivalIndex), [0, 1, 2, 4])
    }

    /// A wait has an end of its own: once the row has been silent long enough to offer its
    /// `×`, the reader stops. Otherwise a dialog left open overnight is a file read every ten
    /// seconds all night, for a row the person can already clear — and a working session has
    /// no such bound, because its quiet is the fault being watched for.
    func testAWaitSilentPastTheDismissThresholdIsNoLongerRead() {
        let threshold = SessionFreshnessEvaluator.defaultDisconnectAfter
        let watchable = TranscriptWatcher.watchableSessions(
            [
                testSession(index: 0, phase: .waitingForUser, lastObservedAt: start),
                testSession(index: 1, phase: .waitingForUser, lastObservedAt: start - threshold),
                testSession(index: 2, phase: .executing, lastObservedAt: start - threshold),
            ],
            now: start + 1
        )

        XCTAssertEqual(watchable.map(\.arrivalIndex), [0, 2])
    }

    /// The case that was missed: a permission dialog dismissed with Esc. The hooks say
    /// nothing, the transcript says everything, and only a reader that looks at a waiting
    /// session ever sees it.
    func testADialogDismissedWithEscIsNoticedWhileTheRowWaitsForAnAnswer() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        var waiting = working()
        waiting.phase = .waitingForUser
        waiting.userInputRequestKind = .approval
        watcher.update(sessions: [waiting])
        _ = try await poll(watcher)

        try append(
            """
            {"type":"user","interruptedMessageId":"message-1","timestamp":"2026-09-05T02:09:56Z","message":{"role":"user","content":\
            [{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
            """
        )

        let facts = try await poll(watcher).flatMap(\.facts)
        XCTAssertEqual(facts, [.turnInterrupted(at: Date(timeIntervalSince1970: 1_788_574_196))])
    }

    /// `AGENTS.md` forbids polling while there is nothing to poll for, and a widget full of
    /// finished sessions is exactly that state.
    func testTheTimerRunsOnlyWhileSomeSessionClaimsToBeWorking() throws {
        let watcher = try makeWatcher()
        XCTAssertFalse(watcher.isPolling)

        watcher.update(sessions: [working()])
        XCTAssertTrue(watcher.isPolling)

        watcher.update(sessions: [testSession(phase: .completed, lastObservedAt: start)])
        XCTAssertFalse(watcher.isPolling)
    }

    /// The timer fires once now instead of repeating, so every tick has to leave a successor
    /// behind. A tick landing while a read is still running is the case that gets this wrong:
    /// it has nothing to schedule from, and a reader that schedules nothing stops for good.
    func testATickDuringAReadStillLeavesTheNextReadScheduled() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])

        let reported = expectation(description: "a poll reported back")
        arrival = reported
        inbox = []
        watcher.poll()
        watcher.timerFired()
        XCTAssertTrue(watcher.isPolling, "a read in flight is reading, whatever the timer holds")

        await fulfillment(of: [reported], timeout: 2)
        arrival = nil

        XCTAssertTrue(watcher.isPolling, "the finished read scheduled the next one")
        XCTAssertEqual(watcher.nextReadAt, start.addingTimeInterval(6))
    }

    /// The point of the schedule: a read lands just after something happened, instead of
    /// wherever a fixed timer's phase put it.
    func testAHookBringsTheNextReadForwardOfTheIdleDeadline() throws {
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])
        let deadline = try XCTUnwrap(watcher.nextReadAt)

        clock = start.addingTimeInterval(4)
        watcher.noteHook(at: clock)

        XCTAssertEqual(try XCTUnwrap(watcher.nextReadAt), clock.addingTimeInterval(0.5))
        XCTAssertLessThan(try XCTUnwrap(watcher.nextReadAt), deadline)
    }

    func testTurningReadingOffStopsTheTimerAndClearsWhatItHadReported() throws {
        let settings = try makeSettings()
        let watcher = makeWatcher(settings: settings)
        watcher.update(sessions: [working()])
        XCTAssertTrue(watcher.isPolling)

        settings.setTranscriptPollInterval(nil)
        watcher.settingsChanged()

        XCTAssertFalse(watcher.isPolling)
        XCTAssertEqual(inbox.count, 1)
        XCTAssertNil(inbox.first?.fault, "a warning left by a reader that has stopped is a claim about nobody")
    }

    // MARK: - Helpers

    private func makeSettings() throws -> WidgetSettingsStore {
        let settings = WidgetSettingsStore(preferences: try isolatedPreferences())
        settings.setTranscriptPollInterval(3)
        return settings
    }

    // MARK: - Catching up a restored session

    /// A session restored from a previous launch is `disconnected`, so `watchableSessions`
    /// leaves it out and the timer will never read it. Its age would then be whatever the file
    /// remembered — the write window plus however long the app was down — printed in orange
    /// under "no signal". One look at the transcript settles it without reading a line of it:
    /// when the file was last written is when the session last did something.
    ///
    /// And no fact is taken, which is the point rather than an omission. A fact can move a
    /// phase — `turnInterrupted` does — and a restored session's phase has to come from its
    /// first real hook.
    func testCatchingUpTakesTheAgeFromTheFileAndNoFactFromIt() async throws {
        try write(toolResult(id: "call-old"))
        let lastWritten = Date(timeIntervalSince1970: 4_800)
        try FileManager.default.setAttributes([.modificationDate: lastWritten], ofItemAtPath: transcriptURL.path)
        let watcher = try makeWatcher()

        let updates = try await catchUp(watcher, sessions: [restored()])

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.newestRecordAt, lastWritten)
        XCTAssertTrue(updates.flatMap(\.facts).isEmpty, "the file says when, not what")
        XCTAssertNil(updates.first?.fault, "a session from a previous launch is nothing to complain about")
    }

    func testUndatedHistoricalInterruptionDoesNotRetractARememberedWait() async throws {
        try write(
            #"{"type":"user","interruptedMessageId":"old-message","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        )
        let watcher = try makeWatcher()
        let session = restored()
        let wait = SessionHistory.RememberedWait(
            dialogs: [AwaitedDialog(activityID: "call-current", kind: .approval)],
            observedAt: start
        )
        let updates = try await catchUp(watcher, sessions: [session], waits: [session.id: wait])
        XCTAssertTrue(SessionHistory.waitStillHolds(wait, evidence: updates.first?.waitEvidence))
    }

    /// A launch is not an exception to the setting.
    ///
    /// Turning reading off promises the transcript is not read; catching up reads the same
    /// file the same way and can move a phase out of it — a remembered wait comes back from
    /// exactly this evidence. So it declines, and answers nobody. The caller settles the
    /// waits it was not given, which is what stops a row waiting for an answer forever.
    func testCatchingUpIsDeclinedWhileReadingIsTurnedOff() throws {
        try write(toolResult(id: "call-old"))
        let settings = try makeSettings()
        settings.setTranscriptPollInterval(nil)
        let watcher = makeWatcher(settings: settings)
        inbox = []

        let asked = watcher.catchUp(sessions: [restored()])

        XCTAssertTrue(asked.isEmpty, "no session was read, so none is claimed to have been")
        XCTAssertTrue(inbox.isEmpty, "and nothing is reported about a file nobody opened")
    }

    /// Catching up leaves the reader where an ordinary first read would have left it: at the
    /// end. Otherwise the session's next real read would replay its whole history.
    func testCatchingUpLeavesTheReaderAtTheEndOfTheFile() async throws {
        try write(toolResult(id: "call-old"))
        let watcher = try makeWatcher()
        _ = try await catchUp(watcher, sessions: [restored()])

        watcher.update(sessions: [working()])
        try append(toolResult(id: "call-new"))
        let updates = try await poll(watcher)

        XCTAssertEqual(
            updates.flatMap(\.facts),
            [
                .callReturned(
                    activityID: HookCaptureRedactor.label(forRawIdentifier: "call-new"),
                    at: Date(timeIntervalSince1970: 1_788_574_196)
                )
            ]
        )
    }

    /// A session renames itself as its work moves on, and a restarted app was not there to
    /// hear it. The name is written near the end of the file rather than in its opening
    /// record, so this is a read of the tail — the opening record that carries the model
    /// would give a name three topics out of date.
    func testCatchingUpTakesTheSessionsCurrentNameFromTheEndOfTheFile() async throws {
        try write(toolResult(id: "call-old"))
        try append(aiTitle("what the session is about now"))
        let watcher = try makeWatcher()

        let updates = try await catchUp(watcher, sessions: [restored()])

        XCTAssertEqual(updates.first?.description?.title, "what the session is about now")
    }

    /// The branch moves while the app is down more surely than anything else here — that is
    /// what a person does between sessions. It comes out of the same read as the name.
    func testCatchingUpTakesTheBranchTheSessionIsOnNow() async throws {
        try write(toolResult(id: "call-old"))
        try append(claudeRecord(branch: "widget-settings"))
        let watcher = try makeWatcher()

        let updates = try await catchUp(watcher, sessions: [restored()])

        XCTAssertEqual(updates.first?.description?.gitBranch, "widget-settings")
    }

    /// Only the catch-up pays for this. While hooks are arriving they carry the name and the
    /// branch already, so an ordinary poll reading a quarter of a megabyte off the end of
    /// every working session's file would be buying what it has been given.
    func testAnOrdinaryPollDoesNotReadTheTailForADescription() async throws {
        try write(toolResult(id: "call-old"))
        try append(aiTitle("what the session is about now"))
        let watcher = try makeWatcher()
        watcher.update(sessions: [working()])

        let updates = try await poll(watcher)

        XCTAssertNil(updates.first?.description)
    }

    /// Codex keeps a thread's name away from its transcript, in an index keyed by the raw
    /// session identifier — which the app does not have. It gets there the way it finds the
    /// transcript itself: by hashing every identifier in the index and looking for its own
    /// label. Worth catching up, because these names change: measured on a real index, a
    /// thread starts as `New voice chat` and is renamed once it is about something.
    func testCatchingUpTakesACodexThreadsNameFromTheIndexBesideIt() async throws {
        try writeCodex([Self.codexOpening])
        try writeCodexThreadIndex(naming: "Realtime Voice Chat")
        let watcher = try makeWatcher()

        var restoredCodex = workingCodex()
        restoredCodex.phase = .disconnected

        let updates = try await catchUp(watcher, sessions: [restoredCodex])

        XCTAssertEqual(updates.first?.description?.title, "Realtime Voice Chat")
    }

    /// The same session as `working()`, in the state a restart leaves it in.
    private func restored() -> SessionSnapshot {
        var session = working()
        session.phase = .disconnected
        session.lastObservedAt = start - 3_600
        return session
    }

    /// One catch-up, waited out, for the same reason `poll` is waited out.
    private func catchUp(
        _ watcher: TranscriptWatcher,
        sessions: [SessionSnapshot],
        waits: [String: SessionHistory.RememberedWait] = [:]
    ) async throws -> [TranscriptUpdate] {
        let reported = expectation(description: "the catch-up reported back")
        arrival = reported
        inbox = []
        watcher.catchUp(sessions: sessions, waits: waits)
        await fulfillment(of: [reported], timeout: 2)
        arrival = nil
        return inbox
    }

    private func makeWatcher() throws -> TranscriptWatcher {
        makeWatcher(settings: try makeSettings())
    }

    private func makeWatcher(settings: WidgetSettingsStore) -> TranscriptWatcher {
        let watcher = TranscriptWatcher(
            settings: settings,
            home: home,
            now: { [weak self] in self?.clock ?? Date() },
            onUpdates: { [weak self] updates in
                self?.inbox = updates
                self?.arrival?.fulfill()
            }
        )
        let root = home
        addTeardownBlock {
            await MainActor.run { watcher.stop() }
            try? FileManager.default.removeItem(at: root)
        }
        return watcher
    }

    /// One poll, waited out. The reading happens off the main thread, so a test that did not
    /// wait would assert against the state from before the read landed.
    private func poll(_ watcher: TranscriptWatcher) async throws -> [TranscriptUpdate] {
        let reported = expectation(description: "a poll reported back")
        arrival = reported
        inbox = []
        watcher.poll()
        await fulfillment(of: [reported], timeout: 2)
        arrival = nil
        return inbox
    }

    /// One poll that must report nothing at all. An inverted expectation rather than a wait
    /// on the timer: the reader calls back only when it has something to say, so silence is
    /// the observation being made here.
    private func pollExpectingNothing(_ watcher: TranscriptWatcher) async {
        let reported = expectation(description: "nothing was reported")
        reported.isInverted = true
        arrival = reported
        inbox = []
        watcher.poll()
        await fulfillment(of: [reported], timeout: 0.3)
        arrival = nil
    }

    /// Readable by nobody, including its owner. The directory stays writable, so the file can
    /// still be removed when the test is over.
    private func lockTranscript() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: transcriptURL.path)
    }

    private func workingCodex() -> SessionSnapshot {
        SessionSnapshot(
            id: SessionSnapshot.id(
                source: .codex,
                sessionLabel: HookCaptureRedactor.label(forRawIdentifier: codexSessionUUID)
            ),
            source: .codex,
            arrivalIndex: 0,
            phase: .executing,
            lastObservedAt: start
        )
    }

    /// Named the way Codex names them: a timestamp, then the session identifier.
    private var codexTranscriptURL: URL {
        home
            .appendingPathComponent(".codex/sessions/2026/09/05", isDirectory: true)
            .appendingPathComponent("rollout-2026-09-05T00-00-00-\(codexSessionUUID).jsonl")
    }

    private func writeCodex(_ lines: [String]) throws {
        try Data(lines.map { "\($0)\n" }.joined().utf8).write(to: codexTranscriptURL)
    }

    private func writeCodexThreadIndex(naming threadName: String) throws {
        try Data(
            """
            {"id":"\(codexSessionUUID)","thread_name":"New voice chat"}
            {"id":"\(codexSessionUUID)","thread_name":"\(threadName)"}

            """.utf8
        ).write(to: home.appendingPathComponent(".codex/session_index.jsonl"))
    }

    private func appendCodex(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: codexTranscriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    private static let codexOpening = """
        {"type":"session_meta","timestamp":"2026-09-05T00:00:00.000Z","payload":{"session_id":"s",\
        "thread_source":"subagent","agent_nickname":"Darwin","git":{"branch":"survey-foundation"}}}
        """

    private static let codexTurnContext = """
        {"type":"turn_context","timestamp":"2026-09-05T00:01:00.000Z","payload":{"turn_id":"t",\
        "model":"gpt-5.6-terra","effort":"high"}}
        """

    private static let codexTokenCount = """
        {"type":"event_msg","timestamp":"2026-09-05T00:01:30.000Z","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":3612721},\
        "last_token_usage":{"input_tokens":124247},"model_context_window":258400}}}
        """

    private func working() -> SessionSnapshot {
        SessionSnapshot(
            id: SessionSnapshot.id(
                source: .claude,
                sessionLabel: HookCaptureRedactor.label(forRawIdentifier: sessionUUID)
            ),
            source: .claude,
            arrivalIndex: 0,
            phase: .executing,
            lastObservedAt: start
        )
    }

    private var projectDirectory: URL {
        home.appendingPathComponent(".claude/projects/-Users-someone-project", isDirectory: true)
    }

    private var transcriptURL: URL {
        projectDirectory.appendingPathComponent("\(sessionUUID).jsonl")
    }

    private func write(_ line: String) throws {
        try Data("\(line)\n".utf8).write(to: transcriptURL)
    }

    private func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(line)\n".utf8))
    }

    private func claudeRecord(branch: String) -> String {
        """
        {"type":"user","timestamp":"2026-09-05T02:09:57Z","gitBranch":"\(branch)",\
        "message":{"role":"user","content":[]}}
        """
    }

    private func aiTitle(_ title: String) -> String {
        """
        {"type":"ai-title","aiTitle":"\(title)","sessionId":"\(sessionUUID)"}
        """
    }

    private func toolResult(id: String) -> String {
        """
        {"type":"user","timestamp":"2026-09-05T02:09:56Z","message":{"role":"user","content":\
        [{"type":"tool_result","tool_use_id":"\(id)"}]}}
        """
    }
}
