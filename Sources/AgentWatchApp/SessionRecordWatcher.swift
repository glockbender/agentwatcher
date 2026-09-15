import AgentWatchCore
import Foundation

/// Watches Claude Code's own record of a process for the one fact nothing else reports: the
/// dialog this session was waiting on is gone.
///
/// Sits beside `TranscriptWatcher` and answers a different question. The transcript says what
/// the session *did* — and says nothing at all between the record of a tool call and its
/// result, which is exactly the stretch a person spends answering and a command spends
/// running. This file says what the session *is*, and Claude Code rewrites it the moment the
/// dialog closes.
///
/// Only while a person is being asked something, and that is what keeps it within
/// `AGENTS.md`'s rule against polling: a row nobody is being asked about is not read at all,
/// so the resting state of this watcher is stopped. While a dialog is up there is exactly one
/// thing to watch for, one small file per waiting row.
///
/// A timer rather than a file-system source, and the reason is symmetry rather than evidence
/// against the alternative. A `DispatchSource` on the file was written first and worked; the
/// test that looked like it failing was reading a row a made-up process number had already
/// closed, so nothing here shows the source to be worse. With the two even, this is the one
/// that reads like `TranscriptWatcher` next door — and half a second is nothing against the
/// 89 being fixed.
///
/// Claude only. Codex keeps no such record, and the engine refuses the fact for a Codex row
/// besides.
@MainActor
final class SessionRecordWatcher {
    /// How often a watched record is read. Short because a person is on the other side of it,
    /// and cheap because it is one small file per row being asked something — which is almost
    /// always none, and rarely more than one.
    static let interval: TimeInterval = 0.5

    private let claudeHome: URL
    private let onStatus: (String, ClaudeSessionStatus) -> Void
    /// The process each watched row runs on, and the last reading announced for it. The
    /// reading is kept so that a record which has not changed is not announced twice a
    /// second.
    private var watched: [String: (processID: Int32, announced: ClaudeSessionStatus?)] = [:]
    private var timer: Timer?

    init(claudeHome: URL, onStatus: @escaping (String, ClaudeSessionStatus) -> Void) {
        self.claudeHome = claudeHome
        self.onStatus = onStatus
    }

    /// Whether any record is being read at all.
    ///
    /// Exposed for the reason `TranscriptWatcher.isPolling` is: the rule that nothing is read
    /// while nothing waits is worth nothing if no test can see it.
    var isWatching: Bool {
        timer != nil
    }

    /// The rows worth reading a record for: a Claude session being asked something, whose
    /// process this app knows. Every other row changes by a hook.
    static func watchableSessions(_ sessions: some Collection<SessionSnapshot>) -> [SessionSnapshot] {
        sessions.filter { $0.source == .claude && $0.phase == .waitingForUser && $0.agentProcessID != nil }
    }

    func update(sessions: [SessionSnapshot]) {
        let wanted = Dictionary(
            Self.watchableSessions(sessions).compactMap { snapshot in
                snapshot.agentProcessID.map { (snapshot.id, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        watched = watched.filter { wanted[$0.key] == $0.value.processID }
        for (id, processID) in wanted where watched[id] == nil {
            watched[id] = (processID, nil)
        }

        guard !watched.isEmpty else {
            stop()
            return
        }
        guard timer == nil else {
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            // Read on the spot. A timer on the main run loop already fires on this actor's
            // own thread, and hopping through a task would put the read behind whatever is
            // running there — which, measured, meant it never happened at all while a caller
            // held the main actor without suspending.
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        // Read straight away rather than waiting out the first tick: the dialog may already
        // have been answered — the app can be launched, or a row restored, while the call it
        // approved is still running. After the timer exists, because announcing a reading
        // publishes, and a publish comes back through `update`.
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One read of every watched record. A reading equal to the one already announced is
    /// dropped here rather than in the engine, so the debug log is not a heartbeat.
    func poll() {
        for (id, entry) in watched {
            guard
                let contents = try? Data(
                    contentsOf: BackgroundSessionAttach.sessionRecordURL(
                        claudeHome: claudeHome, agentProcessID: entry.processID)),
                let status = ClaudeSessionStatus(sessionRecord: contents),
                status != entry.announced
            else {
                continue
            }
            watched[id]?.announced = status
            onStatus(id, status)
        }
    }
}
