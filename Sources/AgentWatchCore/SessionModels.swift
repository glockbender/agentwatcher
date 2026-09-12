import Foundation

public enum AgentSource: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

/// Where the agent session is running. The absence of a value is deliberate:
/// the sender only reports this when it can identify the host reliably.
public enum SessionClientKind: String, Codable, Sendable {
    case desktop
    case cli
    /// A session the agent runs for itself, in a pty of its own rather than in a terminal:
    /// Claude Code's background sessions, hosted by `claude bg-pty-host`.
    ///
    /// A third place rather than a flavour of `cli`, because it answers the widget's `↗`
    /// differently from both others. A terminal session and a desktop one have a window to
    /// bring forward; this one never had and never will — its process tree ends at `launchd`,
    /// measured, with no application anywhere above it. Its `↗` opens a terminal tab with
    /// `claude attach` instead (`BackgroundSessionAttach`).
    case background
}

/// How much of the context window a session is carrying.
///
/// The percentage is optional because the two ways this arrives know different things. A
/// provider that reports a percentage knows its own window size; a transcript reports token
/// counts and never says what they are a fraction of. Inventing the denominator from a table
/// of model window sizes would be a number that goes quietly wrong on the next model.
public struct SessionContextTelemetry: Codable, Equatable, Sendable {
    public let totalInputTokens: Int
    public let usedPercentage: Double?

    public init(totalInputTokens: Int, usedPercentage: Double? = nil) {
        self.totalInputTokens = totalInputTokens
        self.usedPercentage = usedPercentage
    }
}

/// How much of an account-level window has been spent.
///
/// The percentage alone. The reset time is reported by the provider and would make a useful
/// line one day — "5h 17% · resets in 40m" — but nothing shows it today, and a field that
/// crosses a process boundary without a reader is surface with no benefit.
public struct UsageWindow: Codable, Equatable, Sendable {
    public let usedPercentage: Double

    public init(usedPercentage: Double) {
        self.usedPercentage = usedPercentage
    }
}

/// Account-level usage. It is intentionally separate from a session's context:
/// no provider should be presented as having a per-session quota it does not expose.
public struct AgentUsageLimits: Codable, Equatable, Sendable {
    public let source: AgentSource
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let observedAt: Date

    public init(
        source: AgentSource,
        fiveHour: UsageWindow? = nil,
        sevenDay: UsageWindow? = nil,
        observedAt: Date
    ) {
        self.source = source
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.observedAt = observedAt
    }
}

public enum SessionMode: String, Codable, Sendable {
    case standard
    case plan
    case unknown
}

public enum SessionPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case planning
    case executing
    case waitingForUser
    case waitingForChildren
    case completed
    case failed
    case disconnected
    case sessionClosed

    /// Whether the session says work is under way right now.
    ///
    /// The one question two different rules were each answering with their own switch, in
    /// exactly opposite directions — whether quiet is accounted for, and whether age is worth
    /// tracking. Both are this, and nothing checked that the two agreed. The compiler forces
    /// a new phase to be classified once, here.
    ///
    /// The three that claim work are also the three where quiet means nothing by itself: a
    /// build runs for minutes without a word. The other six explain their own silence — the
    /// turn ended, a person is being waited for, the session is closed or lost, or it is at
    /// rest between turns.
    public var claimsWork: Bool {
        switch self {
        case .planning, .executing, .waitingForChildren: true
        case .idle, .waitingForUser, .completed, .failed, .disconnected, .sessionClosed: false
        }
    }
}

public enum UserInputRequestKind: String, Codable, Sendable {
    case approval
    case selection
}

public enum ActivityKind: String, Codable, Sendable {
    case shell
    case subagent
    case backgroundTask
    /// The agent is compacting its own context: `PreCompact` opens it, `PostCompact` ends it.
    ///
    /// Not a tool call — nothing the agent was asked to do — but it takes real time and it is
    /// the reason the session went quiet, which is exactly what a reader is asking.
    case compaction
    /// The agent is consulting a stronger reviewer.
    ///
    /// The one kind no hook can report: the call runs on Anthropic's side rather than in the
    /// client, so neither `PreToolUse` nor `PostToolUse` fires for it. It reaches the app only
    /// through the transcript, and only for Claude — Codex has no equivalent.
    case advisor
    case tool
}

public struct SessionActivity: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: ActivityKind
    public let startedAt: Date
    public let parentID: String?
    /// Whether this call can still be running once the turn that issued it has ended.
    ///
    /// A subagent and a background shell can. `Stop` fires for the main agent while a
    /// subagent it spawned is still working, and that subagent's own end arrives later as
    /// `SubagentStop`; a background shell simply runs on, and was measured still running
    /// almost three minutes after its `Stop`. Every other call is finished by the time the
    /// turn ends — which is what lets `Stop` clear calls whose ending never arrived at all.
    ///
    /// The two differ in what releases them, so `turnStarted` sweeps the background shell
    /// and keeps the subagent: see `SessionReducer`.
    ///
    /// Declared at the point the activity is created rather than inferred from its kind: a
    /// subagent *tool call* that was denied is also `.subagent`, and it does not outlive
    /// anything.
    public let outlivesTurn: Bool
    /// Whether the work continues after the tool call that started it reports back.
    ///
    /// A background shell does: measured on real transcripts, the call hands back a handle
    /// in about five seconds while the command runs on. Its true end is not observable
    /// through hooks at all, so the start of the next turn is the bound — the least wrong
    /// one available, and the only one that cannot accumulate work that finished long ago.
    ///
    /// Independent of `outlivesTurn`, and both are needed: a subagent outlives the turn and
    /// is ended by `SubagentStop`, a background shell outlives it and is ended by nothing
    /// but the next turn starting.
    public let outlivesItsCall: Bool

    public init(
        id: String,
        kind: ActivityKind,
        startedAt: Date,
        parentID: String? = nil,
        outlivesTurn: Bool = false,
        outlivesItsCall: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.parentID = parentID
        self.outlivesTurn = outlivesTurn
        self.outlivesItsCall = outlivesItsCall
    }
}

public struct SessionSnapshot: Identifiable, Codable, Equatable, Sendable {
    public let id: String

    /// The identifier for a session of one source, and the only place its shape is decided.
    ///
    /// Two sources can hand out the same session label, so the source is part of the key.
    public static func id(source: AgentSource, sessionLabel: String) -> String {
        "\(source.rawValue):\(sessionLabel)"
    }

    /// The session's own label, without the source prefix. This is the label a transcript
    /// file name hashes to, which is how `TranscriptLocator` finds the file.
    public var sessionLabel: String {
        String(id.dropFirst(source.rawValue.count + 1))
    }

    public let source: AgentSource
    /// Where the session belongs in a list, fixed at the moment it first appeared.
    ///
    /// The engine counts forward and never reuses an index, so a session keeps its place for
    /// as long as it lives and a new one always joins at the end — including after another
    /// session was removed. Ordering by the most recent event instead kept moving whichever
    /// session spoke last to the top, which reshuffled the list under the reader.
    ///
    /// Assigned by the engine and by nothing else. It is settable only because a session put
    /// back from a previous launch brings an index with it, and the engine has to move it
    /// aside if that one is already taken: see `restore`.
    public var arrivalIndex: Int
    /// The agent's own name for the session, once it has one.
    ///
    /// Optional rather than filled with the product's name: a row already carries the agent's
    /// icon, so a session called "Claude Code" beside the Claude icon said the same thing
    /// twice and pushed the rest of the row along — and the hover card read
    /// `Claude Code` / `Claude Code · CLI · working`. What to show when there is no name is
    /// the widget's decision, and it cannot make it if the model has already decided for it.
    public var title: String?
    /// The project the session is working in, as its directory's own name — never the path
    /// that leads to it. See `docs/architecture.md` §15.
    public var projectName: String?
    public var gitBranch: String?
    public var mode: SessionMode
    public var phase: SessionPhase
    public var userInputRequestKind: UserInputRequestKind?
    /// Which tool call the session is waiting on an answer for.
    ///
    /// Without it any finishing tool cleared the wait, and a session blocked on a permission
    /// dialog went back to reading as `working` the moment an unrelated parallel tool
    /// returned — losing the one signal this widget exists to deliver.
    public var awaitedActivityID: String?
    public var activities: [SessionActivity]
    public var lastObservedAt: Date
    public var agentProcessID: Int32?
    public var clientKind: SessionClientKind?
    public var contextTelemetry: SessionContextTelemetry?
    /// The model the session runs on, as its own agent names it.
    ///
    /// Read from the session's transcript for both agents, which makes it the one signal here
    /// that means the same thing in a Claude row and a Codex row.
    public var modelName: String?
    /// How hard the model was asked to think, where the agent says so. Codex only: Claude
    /// writes nothing equivalent into its transcript.
    public var reasoningEffort: String?
    /// Whether the row is a person's thread or one an agent started for itself.
    ///
    /// Only Codex answers it, because only Codex gives a subagent a session of its own; a
    /// Claude subagent's work is counted as its parent's and never becomes a row. So a Claude
    /// row says nothing here rather than claiming to be a person's.
    public var threadKind: SessionThreadKind?
    public var threadNickname: String?
    /// How much of this row is still known rather than remembered. Never affects the phase.
    ///
    /// Carried on the snapshot rather than in a table beside it because the row, the hover
    /// card and the debug window all show the same value, and a second store would be a
    /// second thing to keep in step with the sessions appearing and leaving.
    public var monitoringFault: MonitoringFault?
    /// The live process this row was built from, when nothing else built it.
    ///
    /// Set on a row the app made out of a running agent it has never heard a hook from, and
    /// on no other row. It is what tells the reconcile which rows it owns, and it is why
    /// such a row is never written to the session memory: the next launch finds the process
    /// again if it is still there, and a remembered copy could only bring back a row for a
    /// process that has since gone.
    ///
    /// Optional, and that is load-bearing beyond the meaning: a synthesized decoder fills an
    /// optional in as `nil` when the key is missing, so a memory file written by an earlier
    /// build still reads. A non-optional field would have thrown, and the read fails open —
    /// one launch would have quietly emptied the file.
    public var discoveredProcess: DiscoveredAgentProcess?

    public init(
        id: String,
        source: AgentSource,
        arrivalIndex: Int,
        title: String? = nil,
        projectName: String? = nil,
        gitBranch: String? = nil,
        mode: SessionMode = .unknown,
        phase: SessionPhase = .idle,
        userInputRequestKind: UserInputRequestKind? = nil,
        awaitedActivityID: String? = nil,
        activities: [SessionActivity] = [],
        lastObservedAt: Date,
        agentProcessID: Int32? = nil,
        clientKind: SessionClientKind? = nil,
        contextTelemetry: SessionContextTelemetry? = nil,
        modelName: String? = nil,
        reasoningEffort: String? = nil,
        threadKind: SessionThreadKind? = nil,
        threadNickname: String? = nil,
        monitoringFault: MonitoringFault? = nil,
        discoveredProcess: DiscoveredAgentProcess? = nil
    ) {
        self.id = id
        self.source = source
        self.arrivalIndex = arrivalIndex
        self.title = title
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.mode = mode
        self.phase = phase
        self.userInputRequestKind = userInputRequestKind
        self.awaitedActivityID = awaitedActivityID
        self.activities = activities
        self.lastObservedAt = lastObservedAt
        self.agentProcessID = agentProcessID
        self.clientKind = clientKind
        self.contextTelemetry = contextTelemetry
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
        self.threadKind = threadKind
        self.threadNickname = threadNickname
        self.monitoringFault = monitoringFault
        self.discoveredProcess = discoveredProcess
    }
}
