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
    /// A third place rather than a flavour of `cli`, because it answers a click on its row
    /// differently from both others. A terminal session and a desktop one have a window to
    /// bring forward; this one never had and never will — its process tree ends at `launchd`,
    /// measured, with no application anywhere above it. Its click opens a terminal tab with
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

/// A kind of work a session left running when its turn ended.
///
/// Claude Code lists these in `Stop`'s own `background_tasks`, and the type it writes there
/// is open-ended — its schema says the label "falls back to the raw discriminant for unknown
/// types". So the four this app can name are named and anything else is `other`: a word from
/// an agent must not reach a row unread, and dropping the task instead would lose the one
/// fact worth having, that something is still running.
public enum BackgroundWorkKind: String, Codable, CaseIterable, Equatable, Sendable {
    /// A shell command: the one a person is most likely to be waiting on, and the only kind
    /// that can arrive here without the agent ever asking for the background — Claude Code
    /// moves a foreground command here itself once it outruns its timeout.
    case shell
    case subagent
    /// An MCP tool watching for something to happen.
    case monitor
    case workflow
    case other
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
    /// that leads to it. See ADR-0001.
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
    /// The labels of the sessions that continue this one, oldest first.
    ///
    /// `/bg` and `/fork` copy a conversation into a new process under a new session
    /// identifier — measured on Claude Code 2.1.269, the copy runs as `claude --fork-session
    /// --resume <the original's transcript>` and sends hooks under its own identifier. Those
    /// hooks belong to this row, and this is how the engine knows: `SessionStateEngine.rowID`
    /// reads it on every event. On the row rather than in a map beside the engine, so the
    /// alias is written to the file with the row and survives a restart.
    ///
    /// Optional for the reason `discoveredProcess` gives: a file written before this field
    /// existed must still read.
    public var continuedBy: [String]?

    /// The labels of copies this row let go: sessions that once continued it and are rows of
    /// their own now, because a session before them in the chain — the original, or a copy
    /// copied in turn — took a turn of its own after they joined (`/fork`, or `/bg` followed
    /// by work in the original). Every hook of a copy names the session it was copied from,
    /// so the name alone would join a let-go copy again on its very next hook; this is what
    /// stops it, and it is on the row so the file keeps it and a restart does not fold the
    /// two back into one. Oldest first, never trimmed — a handful of identifiers at most.
    ///
    /// Optional for the reason `discoveredProcess` gives: a file written before this field
    /// existed must still read.
    public var releasedCopies: [String]?

    /// The label the session's transcript is currently written under: the newest copy's, or
    /// the session's own. A copy writes a transcript of its own, named after its own
    /// identifier, and the original's file stops growing the moment the copy starts.
    public var transcriptLabel: String {
        continuedBy?.last ?? sessionLabel
    }

    /// What the session left running when its last turn ended, one entry per task.
    ///
    /// Not an activity, and deliberately not one: an activity is a call the turn is waiting
    /// on, and this is work the turn walked away from. It never moves the phase — the turn
    /// really did end, and a background command wants nothing from a person — so the row says
    /// `completed` and adds what is still running. ADR-0008.
    ///
    /// Reported whole by every `Stop` and believed whole, which is what makes it a
    /// correction rather than a tally: Claude Code sends the full live list each time.
    ///
    /// Optional for the reason `discoveredProcess` gives: a memory file written before this
    /// field existed must still read. `nil` there means the same as empty.
    public var backgroundWork: [BackgroundWorkKind]?

    /// The terminal process a background session is on screen in, when one is.
    ///
    /// `/bg` runs the session on in a process of its own, and that process is what
    /// `agentProcessID` names: it is what the hooks come from and what the row lives and dies
    /// with. But the terminal `/bg` was typed in is not freed — measured on 2.1.269, the
    /// interactive process stays alive, attached to the job, and the session is on screen
    /// right there. That terminal is where a person finds the session, so the click and the
    /// icon belong to it while it is there, and to `claude attach` once it is gone. Only the
    /// app can tell (it is Claude Code's registry and a process list, §14 of the
    /// architecture), and it says so through `SessionStateEngine.setViewer`.
    ///
    /// Optional for the reason `discoveredProcess` gives: a file written before this field
    /// existed must still read.
    public var viewerProcessID: Int32?

    /// The kind of place a click on the row reaches: the terminal showing a background
    /// session, where there is one, and otherwise the kind of the process itself.
    public var hostKind: SessionClientKind? {
        clientKind == .background && viewerProcessID != nil ? .cli : clientKind
    }

    /// The process a click walks up from to find the session's window: the terminal showing
    /// a background session, where there is one, and otherwise the agent's own.
    public var hostProcessID: Int32? {
        clientKind == .background ? viewerProcessID ?? agentProcessID : agentProcessID
    }

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
