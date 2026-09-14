import AgentWatchCore
import AgentWatchSender
import Foundation

/// What one poll of one session's transcript produced.
struct TranscriptUpdate: Sendable {
    let sessionID: String
    let facts: [TranscriptFact]
    /// What the app is no longer sure of, or `nil` when the read went normally. Replaces
    /// whatever the session carried, so a fault that has cleared is cleared here.
    let fault: MonitoringFault?
    /// When the newest line this read picked up was written, or `nil` when the file did not
    /// grow. Set even when nothing in those lines was a fact: growth is proof of life, and
    /// that is the whole difference between a session thinking and a session lost.
    let newestRecordAt: Date?
    /// Everything the session has said about itself so far, not only what this read found.
    /// Accumulated per session, so a poll that saw a model but no counts still carries the
    /// counts an earlier poll saw — the reader is the only source of these, and a gap here
    /// would blank a row rather than leave it as it was.
    let signals: TranscriptSignals
    /// What the session calls itself, read from the end of its file while catching up after a
    /// restart. `nil` on an ordinary poll: while hooks are arriving they carry this, and the
    /// sender resolves it from the same file.
    let description: SessionDescription?
    /// What the file says about a wait the session was remembered in, when one was asked
    /// about. `nil` means the question could not be answered — see
    /// `SessionHistory.waitStillHolds`, where that is a complete answer rather than a gap.
    let waitEvidence: SessionHistory.RememberedWaitEvidence?

    init(
        sessionID: String,
        facts: [TranscriptFact],
        fault: MonitoringFault?,
        newestRecordAt: Date? = nil,
        signals: TranscriptSignals = TranscriptSignals(),
        description: SessionDescription? = nil,
        waitEvidence: SessionHistory.RememberedWaitEvidence? = nil
    ) {
        self.sessionID = sessionID
        self.facts = facts
        self.fault = fault
        self.newestRecordAt = newestRecordAt
        self.signals = signals
        self.description = description
        self.waitEvidence = waitEvidence
    }
}

/// Reads the tail of each working session's own transcript, and says so when it cannot.
///
/// The second source of truth, running beside the hooks rather than instead of them. Hooks
/// are fast and report the beginning of everything; they report an ending only when the call
/// succeeded, and they report nothing at all for an interrupted turn. The transcript records
/// both, a few seconds later. Neither source alone is enough, which is why both run.
///
/// Everything here is scheduling and file handling. The rules — what a record means, which
/// file belongs to a session, whether quiet needs explaining — live in `AgentWatchCore` and
/// are tested without a disk.
@MainActor
final class TranscriptWatcher {
    /// How long a session may go without a transcript before that is reported.
    ///
    /// The file appears when the agent writes its first record, which is after the hook that
    /// announced the session — so a young session with no file is normal, and reporting it
    /// immediately would flag every session at birth.
    static let locateGrace: TimeInterval = 30
    /// How long to wait between attempts once the grace has passed.
    ///
    /// Scanning a root costs tens of milliseconds and grows with a person's history. Retrying
    /// every tick for a session whose file will never appear — the naming convention changed,
    /// the root moved — would pay that forever, for every session at once.
    static let locateRetryInterval: TimeInterval = 60
    /// How long a hook waits before its read, so hooks arriving together cause one.
    ///
    /// Not a wait for the file: measured on this project's own transcript, a record is
    /// already readable before its own hook fires.
    static let coalesceWindow: TimeInterval = 0.5

    private struct Watch {
        var url: URL?
        var offset: UInt64 = 0
        let firstSeenAt: Date
        var nextLocateAttemptAt: Date
        var signals = TranscriptSignals()
        /// The label the file was, or is being, looked for under — `SessionSnapshot.transcriptLabel`.
        /// A row continued by a copy changes it, and the watch starts over on the copy's file.
        let sessionLabel: String
    }

    private struct ReadJob: Sendable {
        let sessionID: String
        let source: AgentSource
        let sessionLabel: String
        let root: URL
        let url: URL?
        let offset: UInt64
        /// Whether a failure to find the file has waited out its grace and may be reported.
        let reportsNotFound: Bool
        /// Only the initial live read recovers facts since observation began.
        var liveSince: Date?
        /// The wait this session was remembered in, when the file is being asked about one.
        var rememberedWait: SessionHistory.RememberedWait?
    }

    private struct ReadResult: Sendable {
        let sessionID: String
        /// The label the file was looked for under, so that `finish` can tell a result meant
        /// for a watch that has since been replaced — a row continued by a copy while a read
        /// of its old file was in flight — and leave the new watch alone.
        let sessionLabel: String
        let url: URL?
        let offset: UInt64
        let facts: [TranscriptFact]
        let fault: MonitoringFault?
        var newestRecordAt: Date?
        var signals = TranscriptSignals()
        /// What the session calls itself, read only when catching up. See `catchUp`.
        var description: SessionDescription?
        /// What the tail says about a remembered wait, read only when one was asked about.
        var waitEvidence: SessionHistory.RememberedWaitEvidence?
    }

    private var watches: [String: Watch] = [:]
    private var sessions: [SessionSnapshot] = []
    private var timer: Timer?
    private var lastReadAt: Date?
    private var hasRead = false
    private var lastHookAt: Date?
    /// Guards against a slow disk stacking one tick on top of the last.
    private var isReading = false

    private let settings: WidgetSettingsStore
    private let home: URL
    private let now: () -> Date
    private let onUpdates: ([TranscriptUpdate]) -> Void

    init(
        settings: WidgetSettingsStore,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping () -> Date = { .now },
        onUpdates: @escaping ([TranscriptUpdate]) -> Void
    ) {
        self.settings = settings
        self.home = home
        self.now = now
        self.onUpdates = onUpdates
    }

    /// Whether the transcript is being read at all — right now, or on a schedule.
    ///
    /// Exposed for the same reason `SessionSupervisor.isPolling` is: `AGENTS.md` forbids
    /// polling with nothing to poll for, and an invariant nothing can observe is one nothing
    /// can hold you to.
    ///
    /// A held timer alone stopped answering this once the timer became one-shot: it is spent
    /// the moment it fires, and the read it started outlives it. The menu asks this question
    /// to say whether reading is happening, so a read in flight has to count.
    var isPolling: Bool {
        timer != nil || isReading
    }

    /// When the next read is due, or `nil` while nothing is being read.
    ///
    /// Observable for the same reason `isPolling` is. This is the whole point of the
    /// schedule — that a read lands just after a hook rather than wherever a fixed timer's
    /// phase happened to put it — and a rule nothing can observe is a rule nothing can hold
    /// you to.
    private(set) var nextReadAt: Date?

    /// A hook arrived for some session.
    ///
    /// Nothing is read here: the state engine has already taken the event, and this only
    /// records that the transcript now probably has something new. It is the best evidence
    /// there is of that, because an agent writes the record before it runs the hook — the
    /// hook spends its first moments merely starting a process.
    func noteHook(at moment: Date) {
        lastHookAt = moment
        rescheduleReads()
    }

    /// The sessions worth reading a transcript for, and the only ones the timer runs for.
    ///
    /// Those whose quiet might end without a hook: a session claiming work, and one waiting
    /// for a person — whose dialog can be dismissed with Esc, which the transcript records and
    /// no hook does. A session at rest or over changes only by a hook, and reading it would be
    /// polling in the resting state, which is exactly what the architecture forbids. The rule
    /// is `SessionSilence.mayEndWithoutAHook`; whether quiet is a *fault* is a different
    /// question, and `merge(_:withSilenceAt:)` still asks that one of `SessionSilence.fault`.
    ///
    /// A wait has an end of its own: once the row has been silent long enough to offer its
    /// `×`, reading stops. A dialog left open overnight would otherwise be a file read every
    /// ten seconds all night for a row the person can already clear. A working session gets
    /// no such bound, because its quiet is the fault being watched for.
    static func watchableSessions(_ sessions: some Collection<SessionSnapshot>, now: Date) -> [SessionSnapshot] {
        sessions.filter { snapshot in
            SessionSilence.mayEndWithoutAHook(snapshot)
                && !(snapshot.phase == .waitingForUser && SessionPresence.isDismissible(snapshot, now: now))
        }
    }

    func update(sessions: [SessionSnapshot]) {
        self.sessions = sessions
        let live = Set(sessions.map(\.id))
        watches = watches.filter { live.contains($0.key) }
        let moment = now()
        for snapshot in Self.watchableSessions(sessions, now: moment)
        where watches[snapshot.id]?.sessionLabel != snapshot.transcriptLabel {
            // A new watch for a new row — or for a row whose transcript has moved: `/bg` and
            // `/fork` continue a session in a copy that writes a file of its own, named after
            // its own identifier, and the original's file stops growing that moment. The copy's
            // file is found and read from its end like any newly found file, so its history
            // — the whole conversation so far — is not replayed.
            watches[snapshot.id] = Watch(
                firstSeenAt: moment, nextLocateAttemptAt: moment, sessionLabel: snapshot.transcriptLabel)
        }
        rescheduleReads()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Applies a change of interval, including turning reading off.
    ///
    /// Turning it off clears every fault it had reported. A warning triangle left behind by a
    /// reader that is no longer running would be a claim about a session nobody is watching.
    func settingsChanged() {
        rescheduleReads()
        guard settings.transcriptPollInterval == nil else {
            return
        }
        watches.removeAll()
        onUpdates(sessions.map { TranscriptUpdate(sessionID: $0.id, facts: [], fault: nil) })
    }

    // MARK: - The tick

    /// What a fired timer does. The timer is spent the moment it fires — it does not
    /// repeat — so it is dropped here, before anything else can decide there is still one.
    func timerFired() {
        timer?.invalidate()
        timer = nil
        nextReadAt = nil
        poll()
    }

    func poll() {
        guard !isReading else {
            // Deliberately schedules nothing. The moment this tick would compute has already
            // passed — it is the one that just fired — so scheduling from it would fire again
            // at once, and again, for as long as the read takes. `finish` schedules instead,
            // from the read that is actually running.
            return
        }
        let moment = now()
        lastReadAt = moment
        hasRead = true
        defer { rescheduleReads() }
        let jobs = makeJobs(at: moment)
        guard !jobs.isEmpty else {
            reportSilenceOnly(at: moment)
            return
        }

        isReading = true
        Task.detached(priority: .utility) { [weak self] in
            let results = Self.perform(jobs, observedAt: moment)
            await MainActor.run { [weak self] in
                self?.finish(results, at: moment)
            }
        }
    }

    /// Catches up sessions restored from a previous launch, once and not on the timer.
    ///
    /// A restored session is `disconnected`, so `watchableSessions` leaves it out — rightly,
    /// because its quiet is accounted for and nothing is going to arrive. What is missing is
    /// not a fact but an age: without this the row would show whatever the memory of the last
    /// launch held, which is the write window plus however long the app was down.
    ///
    /// So the file is asked when it was last written and nothing else. No line of it is
    /// parsed for facts, and that is the point rather than an omission: a fact can move a
    /// phase — `turnInterrupted` does — and a restored session's phase has to come from its
    /// first real hook. The opening record comes along because locating a file reads it
    /// anyway, and every field in it is stated once at the top and never repeated.
    /// - Parameter waits: what each session was remembered waiting for, for the sessions
    ///   whose file has to answer that question too.
    /// - Returns: the sessions this call actually took on. A caller holding a question that
    ///   must be answered — a remembered wait does — needs to know which ones were declined,
    ///   because nothing else will ever come back about them.
    @discardableResult
    func catchUp(
        sessions restored: [SessionSnapshot],
        waits: [String: SessionHistory.RememberedWait] = [:]
    ) -> Set<String> {
        // The setting is not about the timer, it is about the file: turning reading off
        // promises the transcript is not read. This path reads the same file the same way,
        // and a fact out of it can move a phase — a remembered wait comes back from exactly
        // this evidence — so a launch is no exception to it.
        //
        // Answering nobody is safe here: the caller settles every wait it was not given, so
        // no row is left waiting on a read that will never happen.
        guard settings.transcriptPollInterval != nil else {
            return []
        }
        guard !isReading else {
            return []
        }
        let moment = now()
        let jobs: [ReadJob] = restored.compactMap { snapshot in
            guard watches[snapshot.id] == nil else {
                return nil
            }
            watches[snapshot.id] = Watch(
                firstSeenAt: moment, nextLocateAttemptAt: moment, sessionLabel: snapshot.transcriptLabel)
            return ReadJob(
                sessionID: snapshot.id,
                source: snapshot.source,
                sessionLabel: snapshot.transcriptLabel,
                root: TranscriptLocator.defaultRoot(for: snapshot.source, home: home),
                url: nil,
                offset: 0,
                // A file that cannot be found is not news here. A session from a previous
                // launch may have had its transcript cleaned away long ago, and the row makes
                // no claim about it — while a fault would put a warning triangle on the widget
                // at every launch.
                reportsNotFound: false,
                rememberedWait: waits[snapshot.id]
            )
        }
        guard !jobs.isEmpty else {
            return []
        }

        isReading = true
        Task.detached(priority: .utility) { [weak self] in
            let results = Self.locateAndDate(jobs)
            await MainActor.run { [weak self] in
                self?.finish(results, at: moment)
            }
        }
        return Set(jobs.map(\.sessionID))
    }

    private func makeJobs(at moment: Date) -> [ReadJob] {
        Self.watchableSessions(sessions, now: now()).compactMap { snapshot in
            var watch =
                watches[snapshot.id]
                ?? Watch(firstSeenAt: moment, nextLocateAttemptAt: moment, sessionLabel: snapshot.transcriptLabel)
            defer { watches[snapshot.id] = watch }

            if watch.url == nil {
                guard moment >= watch.nextLocateAttemptAt else {
                    return nil
                }
                // The next attempt is booked before the scan runs, not after it returns, so
                // a scan that is still going cannot be started a second time.
                watch.nextLocateAttemptAt = moment + Self.locateRetryInterval
            }
            return ReadJob(
                sessionID: snapshot.id,
                source: snapshot.source,
                sessionLabel: snapshot.transcriptLabel,
                root: TranscriptLocator.defaultRoot(for: snapshot.source, home: home),
                url: watch.url,
                offset: watch.offset,
                reportsNotFound: moment.timeIntervalSince(watch.firstSeenAt) >= Self.locateGrace,
                liveSince: watch.firstSeenAt
            )
        }
    }

    private func finish(_ results: [ReadResult], at moment: Date) {
        isReading = false
        // The read is over, so the next one can be scheduled — and for a tick that arrived
        // while this one ran, this is the only place that will.
        defer { rescheduleReads() }
        var updates: [TranscriptUpdate] = []
        for result in results {
            guard var watch = watches[result.sessionID], watch.sessionLabel == result.sessionLabel else {
                // Nobody's result: the row is gone, or its watch was replaced while the read
                // ran and now looks for another file. Writing this file's address into the
                // new watch would stop it from ever looking.
                continue
            }
            watch.url = result.url
            watch.offset = result.offset
            if result.url != nil {
                // A file that has been found retries locating only if it is lost again.
                watch.nextLocateAttemptAt = moment
            } else {
                // A file found by name and then unusable costs the same scan as one that was
                // never there, so it waits the same minute before the next attempt. The row
                // keeps its warning triangle for that whole minute — blind and flagged, which
                // is the trade being made against blind and silent.
                watch.nextLocateAttemptAt = moment + Self.locateRetryInterval
            }
            watch.signals = watch.signals.merging(result.signals)
            watches[result.sessionID] = watch
            updates.append(
                TranscriptUpdate(
                    sessionID: result.sessionID,
                    facts: result.facts,
                    fault: result.fault,
                    newestRecordAt: result.newestRecordAt,
                    signals: watch.signals,
                    description: result.description,
                    waitEvidence: result.waitEvidence
                )
            )
        }
        onUpdates(merge(updates, withSilenceAt: moment))
    }

    /// The tick when nothing needed reading — every watched session is between locate
    /// attempts. Silence still has to be judged, or a session whose file was never found
    /// would never be reported as silent either.
    private func reportSilenceOnly(at moment: Date) {
        let updates = merge([], withSilenceAt: moment)
        guard !updates.isEmpty else {
            return
        }
        onUpdates(updates)
    }

    /// Adds the one fault that is not about a file: a session that has simply stopped
    /// speaking while claiming to work. Whether that counts is `SessionSilence.fault`'s
    /// question; supplying the two facts it cannot know is this one's.
    private func merge(_ updates: [TranscriptUpdate], withSilenceAt moment: Date) -> [TranscriptUpdate] {
        var byID = Dictionary(uniqueKeysWithValues: updates.map { ($0.sessionID, $0) })
        for snapshot in Self.watchableSessions(sessions, now: now()) {
            let existing = byID[snapshot.id]
            // The rule itself lives in Core, where it can be exercised without an
            // application. What this file contributes is the two facts only it holds: what
            // was read this moment, and whether there is a file to read at all.
            guard
                let fault = SessionSilence.fault(
                    for: snapshot,
                    alreadyFaulted: existing?.fault != nil,
                    sawFreshRecord: existing?.newestRecordAt != nil,
                    isBeingRead: watches[snapshot.id]?.url != nil,
                    now: moment
                )
            else {
                continue
            }
            byID[snapshot.id] = TranscriptUpdate(
                sessionID: snapshot.id,
                facts: existing?.facts ?? [],
                fault: fault
            )
        }
        return Array(byID.values)
    }

    // MARK: - Off the main thread

    /// Locating and reading, away from the main thread.
    ///
    /// `nonisolated` and taking only `Sendable` values, so nothing here can reach the widget
    /// while it is being drawn. A scan of a transcript root was measured at 44 ms, which is
    /// three dropped frames if it happens on the main thread every few seconds.
    private nonisolated static func perform(_ jobs: [ReadJob], observedAt: Date) -> [ReadResult] {
        jobs.map { job in
            guard let url = job.url else {
                return locateLive(job)
            }
            return read(job, at: url, observedAt: observedAt)
        }
    }

    /// Where each session's file stands, and the two questions a restart has to ask of it.
    /// See `catchUp`.
    private nonisolated static func locateAndDate(_ jobs: [ReadJob]) -> [ReadResult] {
        jobs.map { job in
            var result = locate(job)
            guard let url = result.url else {
                return result
            }
            result.newestRecordAt = modificationDate(at: url)
            // Read once and used twice. Claude's name lives in the tail and a remembered
            // wait is answered by the same bytes, so a second read would be a quarter of a
            // megabyte for something already in hand.
            let tail = tailIfNeeded(at: url, for: job)
            result.description = currentDescription(tail: tail, at: url, for: job)
            if let wait = job.rememberedWait {
                result.waitEvidence = waitEvidence(inTail: tail, for: wait, source: job.source)
            }
            return result
        }
    }

    /// The tail, when something is going to ask it a question. Codex keeps its name
    /// elsewhere, so its tail is read only for a wait.
    private nonisolated static func tailIfNeeded(at url: URL, for job: ReadJob) -> Data? {
        guard job.source == .claude || job.rememberedWait != nil else {
            return nil
        }
        return TitleFileSystem.live.readTail(url.path, SessionDescriptionResolver.transcriptTailByteCount)
    }

    /// What the tail says about the wait this session was remembered in.
    ///
    /// Undated records are historical evidence only. Dating them at the wait or at now
    /// would turn an old cancellation into a fresh answer to the remembered dialog.
    private nonisolated static func waitEvidence(
        inTail tail: Data?,
        for wait: SessionHistory.RememberedWait,
        source: AgentSource
    ) -> SessionHistory.RememberedWaitEvidence? {
        guard
            let tail,
            let increment = try? TranscriptReader.read(
                increment: tail,
                source: source,
                observedAt: .distantPast
            )
        else {
            return nil
        }
        return SessionHistory.RememberedWaitEvidence(
            facts: increment.facts,
            awaitedActivityID: wait.awaitedActivityID
        )
    }

    /// What the session calls itself right now, and where the two agents differ most.
    ///
    /// Both are read only while catching up, and both go through the same cap the socket path
    /// applies: these are a model's own words out of a file anything can write to, and
    /// nothing about reading them locally makes them safer than reading them off a socket.
    private nonisolated static func currentDescription(
        tail: Data?,
        at url: URL,
        for job: ReadJob
    ) -> SessionDescription? {
        let described =
            switch job.source {
            case .claude: tail.flatMap(SessionDescriptionResolver.claudeDescription(inTranscriptTail:))
            case .codex: codexDescription(for: job)
            }
        return HookIngressRequest.sanitized(described)
    }

    /// Codex puts a thread's name nowhere near its transcript, so this reads a different file
    /// and takes nothing else from it: the branch and the context size come from the
    /// transcript's own opening record, which `locate` has already read.
    ///
    /// The index is keyed by the raw session identifier, which the app never holds — so the
    /// match is made the way `TranscriptLocator` makes it, by hashing every candidate. The
    /// file is one short record per thread, small enough to read whole.
    private nonisolated static func codexDescription(for job: ReadJob) -> SessionDescription? {
        guard
            let index = try? Data(
                contentsOf: TranscriptLocator.codexThreadIndex(inRoot: job.root)),
            let threadName = CodexThreadIndex.threadName(
                forSessionLabel: job.sessionLabel, inIndex: index)
        else {
            return nil
        }
        return SessionDescription(title: threadName)
    }

    /// When the file was last written, which for a transcript is when its session last said
    /// anything. Cheaper than reading it and, for a session nobody was watching, just as true.
    private nonisolated static func modificationDate(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Recover the coalescing window on the first live read. A bounded tail avoids replaying
    /// the whole history; timestamps reject old and undated facts. Catch-up after relaunch
    /// deliberately uses `locate` instead, because its state still awaits a real hook.
    private nonisolated static func locateLive(_ job: ReadJob) -> ReadResult {
        var result = locate(job)
        guard let url = result.url, let boundary = job.liveSince else {
            return result
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            let start =
                end > UInt64(TranscriptReader.maximumIncrementByteCount)
                ? end - UInt64(TranscriptReader.maximumIncrementByteCount) : 0
            try handle.seek(toOffset: start)
            var data = try handle.read(upToCount: Int(end - start)) ?? Data()
            var offset = start
            if start > 0 {
                // The cap can land inside a record. Never parse that fragment as a new line.
                let skipped =
                    data.firstIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 }
                    ?? data.count
                data = Data(data.dropFirst(skipped))
                offset += UInt64(skipped)
            }
            let increment = try TranscriptReader.read(increment: data, source: job.source, observedAt: boundary)
            result = ReadResult(
                sessionID: job.sessionID, sessionLabel: job.sessionLabel,
                url: url,
                offset: offset + UInt64(increment.consumedByteCount),
                facts: increment.facts.filter { $0.at > boundary },
                fault: nil,
                newestRecordAt: increment.newestRecordAt.flatMap { $0 > boundary ? $0 : nil },
                signals: result.signals.merging(increment.signals)
            )
        } catch {
            result = ReadResult(
                sessionID: job.sessionID, sessionLabel: job.sessionLabel, url: nil, offset: 0, facts: [],
                fault: .transcriptUnreadable)
        }
        return result
    }

    private nonisolated static func locate(_ job: ReadJob) -> ReadResult {
        guard
            let url = TranscriptLocator.locate(
                sessionLabel: job.sessionLabel,
                source: job.source,
                root: job.root
            )
        else {
            return ReadResult(
                sessionID: job.sessionID, sessionLabel: job.sessionLabel,
                url: nil,
                offset: 0,
                facts: [],
                fault: job.reportsNotFound ? .transcriptNotFound : nil
            )
        }

        // Start at the end, never at the beginning. The file holds the session's whole
        // history: reading it from the start would close calls that ended an hour ago and
        // would idle the session on an interruption from before the app was launched.
        //
        // So a file whose end cannot be found is not a file to start reading. Treating an
        // unknown size as zero would do exactly what the paragraph above forbids, and it
        // would do it in the one case where the file is already behaving oddly.
        guard let end = endOfFile(at: url) else {
            return ReadResult(
                sessionID: job.sessionID, sessionLabel: job.sessionLabel,
                url: nil,
                offset: 0,
                facts: [],
                fault: .transcriptUnreadable
            )
        }
        // The one moment the head of the file is worth reading. What it holds — the branch
        // the session started on, whether the thread is a person's — is stated once at the
        // top and never repeated, so no amount of tailing will ever find it. It cannot
        // disturb the tail either: the offset above came from a handle of its own, and a head
        // that will not parse costs these values and nothing else.
        return ReadResult(
            sessionID: job.sessionID, sessionLabel: job.sessionLabel,
            url: url,
            offset: end,
            facts: [],
            fault: nil,
            signals: opening(at: url, source: job.source)
        )
    }

    private nonisolated static func read(_ job: ReadJob, at url: URL, observedAt: Date) -> ReadResult {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()

            // Two ways the saved offset stops meaning anything: the file was replaced or
            // truncated under us, or more has arrived than a live session can produce
            // between two reads. Both are answered by moving to the end and saying so —
            // whatever was in between is genuinely lost, and parsing megabytes to discover
            // that would only spend the time as well.
            guard end >= job.offset else {
                return ReadResult(
                    sessionID: job.sessionID, sessionLabel: job.sessionLabel,
                    url: url,
                    offset: end,
                    facts: [],
                    fault: .transcriptResynchronized
                )
            }
            guard end - job.offset <= UInt64(TranscriptReader.maximumIncrementByteCount) else {
                return ReadResult(
                    sessionID: job.sessionID, sessionLabel: job.sessionLabel,
                    url: url,
                    offset: end,
                    facts: [],
                    fault: .transcriptResynchronized
                )
            }

            try handle.seek(toOffset: job.offset)
            let increment = try TranscriptReader.read(
                increment: try handle.readToEnd() ?? Data(),
                source: job.source,
                observedAt: observedAt
            )
            return ReadResult(
                sessionID: job.sessionID, sessionLabel: job.sessionLabel,
                url: url,
                offset: job.offset + UInt64(increment.consumedByteCount),
                facts: increment.facts,
                fault: nil,
                // The read moment stands in only for lines that carried no timestamp of their
                // own. It is later than the truth by up to one interval, which is why it is
                // the fallback and not the rule.
                newestRecordAt: increment.consumedByteCount > 0
                    ? (increment.newestRecordAt ?? observedAt) : nil,
                signals: increment.signals
            )
        } catch {
            // The file is dropped along with the fault, so the next attempt locates again: a
            // transcript can be deleted or moved, and a path kept forever would report the
            // same failure for a session whose file is fine somewhere else.
            return ReadResult(
                sessionID: job.sessionID, sessionLabel: job.sessionLabel, url: nil, offset: 0, facts: [],
                fault: .transcriptUnreadable)
        }
    }

    /// The opening record, read once when a file is first found.
    private nonisolated static func opening(at url: URL, source: AgentSource) -> TranscriptSignals {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return TranscriptSignals()
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: TranscriptReader.openingByteCount) else {
            return TranscriptSignals()
        }
        return TranscriptReader.readOpening(head, source: source)
    }

    private nonisolated static func endOfFile(at url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        return try? handle.seekToEnd()
    }

    // MARK: - Timer

    private func rescheduleReads() {
        guard
            let floor = settings.transcriptPollInterval,
            !Self.watchableSessions(sessions, now: now()).isEmpty
        else {
            timer?.invalidate()
            timer = nil
            nextReadAt = nil
            lastReadAt = nil
            hasRead = false
            return
        }

        let moment = now()
        // Anchored once, when reading starts, rather than on every call: taking `now` each
        // time would push the first read further away with every session update.
        let anchor = lastReadAt ?? moment
        lastReadAt = anchor
        let due = TranscriptReadSchedule(
            floor: floor,
            idle: floor * 2,
            coalesceWindow: Self.coalesceWindow
        ).nextRead(lastReadAt: anchor, lastHookAt: lastHookAt, isFirstRead: !hasRead)
        guard due != nextReadAt || timer == nil else {
            return
        }

        nextReadAt = due
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: max(0, due.timeIntervalSince(moment)),
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerFired()
            }
        }
    }
}
