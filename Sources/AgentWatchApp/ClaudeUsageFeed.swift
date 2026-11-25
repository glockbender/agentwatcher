import AgentWatchCore
import AgentWatchLookup
import Foundation

/// Claude's plan limits come from Claude Code's own snapshot, and a rare run
/// of Claude Code when the snapshot is old (ADR-0026).
///
/// Ticked by the supervisor's maintenance sweep, which exists only while some session claims
/// work, so nothing here runs while the app is at rest. The file is read only when it changed,
/// and both the read and the run happen off the main thread.
///
/// Only the default folder's `.claude.json` is read: the widget has one line for Claude, and
/// which account's limits a second folder's line would be is a question nobody has asked yet.
@MainActor
final class ClaudeUsageFeed {
    /// One run: what Claude Code replied, or `nil` when nothing usable came back in time.
    typealias Ask = @Sendable () -> ClaudeUsageSnapshot.Reply?

    private let configFile: URL
    private let modificationDate: @Sendable (URL) -> Date?
    private let readFile: @Sendable (URL) -> Data?
    private let ask: Ask?
    private let now: () -> Date
    private var policy = ClaudeUsageProbePolicy()
    private var readModificationDate: Date?
    private(set) var reading = false
    private(set) var probing = false

    /// - Parameter ask: `nil` when there is no Claude Code to start; the snapshot is still read.
    init(
        configFile: URL,
        ask: Ask?,
        now: @escaping () -> Date = Date.init,
        modificationDate: @escaping @Sendable (URL) -> Date? = { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        },
        readFile: @escaping @Sendable (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) {
        self.configFile = configFile
        self.ask = ask
        self.now = now
        self.modificationDate = modificationDate
        self.readFile = readFile
    }

    /// The feed for this Mac: `home/.claude.json`, and the Claude Code `AgentInstallationLookup`
    /// finds, started with `home` as its own.
    static func live(home: URL) -> ClaudeUsageFeed {
        let executable = AgentInstallationLookup.executable(for: .claude, home: home)
            // Never one inside an application bundle: launching that is what raises
            // Gatekeeper's "damaged" warning on the person's screen.
            .flatMap { $0.contains(".app/") ? nil : $0 }
        var ask: Ask?
        if let executable {
            ask = { @Sendable in ClaudeUsageProbe.ask(executable: executable, home: home) }
        }
        return ClaudeUsageFeed(configFile: home.appendingPathComponent(".claude.json"), ask: ask)
    }

    /// One sweep: reads the snapshot if the file changed, then starts a run if the policy says so.
    ///
    /// The run is decided after the read has landed: a snapshot two minutes old, from `/usage`
    /// or another tool, is fresher than anything a run would bring, and on the first sweep
    /// after a launch the app knows of no limits at all until it has read one.
    ///
    /// - Parameters:
    ///   - knownLimitsObservedAt: when the freshest known Claude limits were observed,
    ///     checked after reading the snapshot.
    ///   - claudeIsWorking: a person's Claude session claims work — a headless run, the app's
    ///     own included, does not count.
    ///   - deliver: called on the main actor with each set of limits found.
    func tick(
        knownLimitsObservedAt: @escaping @MainActor () -> Date?,
        claudeIsWorking: Bool,
        deliver: @escaping @MainActor (AgentUsageLimits) -> Void
    ) {
        guard !reading else {
            return
        }
        let file = configFile
        let modificationDate = modificationDate
        let readFile = readFile
        let moment = now()
        let lastRead = readModificationDate
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let modified = modificationDate(file)
            var limits: AgentUsageLimits?
            var settled = modified
            if let modified, modified != lastRead {
                let data = readFile(file)
                limits = data.flatMap { ClaudeUsageSnapshot.limits(inConfigFile: $0, now: moment) }
                // A file caught mid-write is read again on the next sweep; a whole file that
                // holds nothing usable is not, until it changes.
                let isWhole = data.map { (try? JSONSerialization.jsonObject(with: $0)) != nil } ?? false
                if !isWhole {
                    settled = lastRead
                }
            }
            Task { @MainActor in
                self.reading = false
                self.readModificationDate = settled
                if let limits {
                    deliver(limits)
                }
                self.probeIfDue(
                    knownLimitsObservedAt: knownLimitsObservedAt(), claudeIsWorking: claudeIsWorking,
                    deliver: deliver)
            }
        }
    }

    private func probeIfDue(
        knownLimitsObservedAt: Date?,
        claudeIsWorking: Bool,
        deliver: @escaping @MainActor (AgentUsageLimits) -> Void
    ) {
        let moment = now()
        guard
            !probing,
            policy.shouldProbe(
                now: moment, knownLimitsObservedAt: knownLimitsObservedAt, claudeIsWorking: claudeIsWorking)
        else {
            return
        }
        guard let ask else {
            policy.stop()
            return
        }
        policy.recordAttempt(at: moment)
        probing = true
        // A dispatch queue, not a task: the run blocks for up to fourteen seconds, and a task
        // would hold one of the few threads Swift's concurrency shares out for that long.
        DispatchQueue.global(qos: .utility).async {
            let reply = ask()
            Task { @MainActor in
                self.probing = false
                switch reply {
                case let .limits(limits)?:
                    deliver(limits)
                case .noPlanLimits?, .refused?, .unknownShape?:
                    // Asking again cannot help: the sign-in has no plan limits, or this Claude
                    // Code does not know the request or answers it in a shape the app cannot
                    // read. A restart asks once more.
                    self.policy.stop()
                case .unavailableNow?, .unrecognised?, nil:
                    break
                }
            }
        }
    }
}
