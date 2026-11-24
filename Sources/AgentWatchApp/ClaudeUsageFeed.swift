import AgentWatchCore
import AgentWatchLookup
import Foundation

/// Claude's plan limits without the status line: Claude Code's own snapshot, and a rare run
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

    /// One sweep: reads the snapshot if the file changed, and starts a run if the policy says so.
    ///
    /// - Parameters:
    ///   - knownLimitsObservedAt: how old the freshest Claude limits the app holds are, from
    ///     either source; a recent status line makes a run unnecessary.
    ///   - claudeIsWorking: a person's Claude session claims work — a headless run, the app's
    ///     own included, does not count.
    ///   - deliver: called on the main actor with each set of limits found.
    func tick(
        knownLimitsObservedAt: Date?,
        claudeIsWorking: Bool,
        deliver: @escaping @MainActor (AgentUsageLimits) -> Void
    ) {
        readSnapshotIfChanged(deliver: deliver)
        probeIfDue(knownLimitsObservedAt: knownLimitsObservedAt, claudeIsWorking: claudeIsWorking, deliver: deliver)
    }

    private func readSnapshotIfChanged(deliver: @escaping @MainActor (AgentUsageLimits) -> Void) {
        guard !reading else {
            return
        }
        let file = configFile
        let modificationDate = modificationDate
        let readFile = readFile
        let moment = now()
        let lastRead = readModificationDate
        reading = true
        Task.detached {
            let modified = modificationDate(file)
            let limits: AgentUsageLimits? =
                if let modified, modified != lastRead {
                    readFile(file).flatMap { ClaudeUsageSnapshot.limits(inConfigFile: $0, now: moment) }
                } else {
                    nil
                }
            await MainActor.run {
                self.reading = false
                self.readModificationDate = modified
                if let limits {
                    deliver(limits)
                }
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
        Task.detached {
            let reply = ask()
            await MainActor.run {
                self.probing = false
                switch reply {
                case let .limits(limits)?:
                    deliver(limits)
                case .noPlanLimits?, .refused?:
                    // Asking again cannot help: the sign-in has no plan limits, or this Claude
                    // Code does not know the request. A restart asks once more.
                    self.policy.stop()
                case .unrecognised?, nil:
                    break
                }
            }
        }
    }
}
