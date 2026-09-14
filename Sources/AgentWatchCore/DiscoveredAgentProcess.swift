import Foundation

/// A live agent process the app has never heard a hook from.
///
/// A running agent is a session whether or not this app was there when it started. Until
/// now the app learned of a session only from a hook, so an agent that had been working
/// since before the app was launched — or since before the hooks were installed — was
/// invisible, and no event was ever going to arrive to fix that: the next hook comes with
/// the next turn, and a session waiting for a person may never take one.
///
/// What such a row can say is limited on purpose. The process knows where it is working and
/// when it started, and that is all: what the session is called, what it is doing and which
/// file it writes are things only the agent can say.
///
/// A process is never *guessed* into a transcript file, and that was measured: `claude` does
/// not hold its transcript open, only three of eight processes were alone in their directory,
/// and a session can be days older than the process now running it — so a match made from
/// directories and timestamps would be a guess dressed as a fact. The one honest match is a
/// pairing the agent itself once stated, in a hook: `knownSessionLabel`.
public struct DiscoveredAgentProcess: Codable, Equatable, Sendable {
    public let source: AgentSource
    public let processID: Int32
    /// When the process started. Both the age the row shows and half of its identity.
    public let startedAt: Date
    /// The name of the directory the process is working in — never the path that leads to
    /// it, which is the same rule `SessionSnapshot.projectName` follows. See
    /// `docs/architecture.md` §15.
    public let projectName: String?
    /// Which session this process is, when a hook has said so before — see
    /// `RememberedAgentProcess`. A row that knows it is a session by name can be asked the
    /// same questions any other session can: which file it writes, and therefore what it is
    /// called.
    public let knownSessionLabel: String?
    /// The kind of place the process runs in, as the scanner saw it — the same question the
    /// sender answers for a hook, asked of the same process tree, so a row built here and the
    /// row a hook builds cannot disagree about whether a click raises a window or attaches.
    /// Optional so that a record without it still reads; `nil` means the ordinary answer.
    public let clientKind: SessionClientKind?

    public init(
        source: AgentSource,
        processID: Int32,
        startedAt: Date,
        projectName: String?,
        knownSessionLabel: String? = nil,
        clientKind: SessionClientKind? = nil
    ) {
        self.source = source
        self.processID = processID
        self.startedAt = startedAt
        self.projectName = projectName
        self.knownSessionLabel = knownSessionLabel
        self.clientKind = clientKind
    }

    /// The same process, now known to be a particular session.
    public func knowing(sessionLabel: String) -> DiscoveredAgentProcess {
        DiscoveredAgentProcess(
            source: source,
            processID: processID,
            startedAt: startedAt,
            projectName: projectName,
            knownSessionLabel: sessionLabel,
            clientKind: clientKind
        )
    }

    /// This run of this process, named so that it can be recognised again.
    ///
    /// The start time is part of it because macOS reuses process numbers. Keyed on the
    /// number alone, a row would survive its own process: the number comes back attached to
    /// something else, the reconcile sees it still running, and a dead session stays on the
    /// widget wearing a stranger's age.
    public var processLabel: String {
        Self.processLabel(processID: processID, startedAt: startedAt)
    }

    /// The same name, for a caller holding the two numbers and no process to go with them.
    public static func processLabel(processID: Int32, startedAt: Date) -> String {
        "process-\(processID)-\(Int(startedAt.timeIntervalSince1970))"
    }

    /// The session label a row built from this process carries: the session's own, when one
    /// is known, and otherwise the process's — which is all this row is.
    public var sessionLabel: String {
        knownSessionLabel ?? processLabel
    }

    /// How this process is identified among sessions, once it becomes a row.
    public var snapshotID: String {
        SessionSnapshot.id(source: source, sessionLabel: sessionLabel)
    }

    /// The row this process is worth on its own.
    ///
    /// `disconnected` — "no signal" — rather than any phase that claims work, and that is
    /// not a formality. A phase claiming work with an empty activity list and an age of
    /// hours is exactly the shape `SessionSilence.isUnexplained` reports as a fault, so
    /// every discovered row would arrive wearing a warning triangle. `disconnected` says
    /// precisely what is known: something is running here and nothing has been heard from
    /// it.
    public func row(arrivalIndex: Int) -> SessionSnapshot {
        SessionSnapshot(
            id: snapshotID,
            source: source,
            arrivalIndex: arrivalIndex,
            projectName: projectName,
            phase: .disconnected,
            lastObservedAt: startedAt,
            agentProcessID: processID,
            clientKind: clientKind ?? .cli,
            discoveredProcess: self
        )
    }
}

/// Which session a live agent process is, as one of that session's hooks once said.
///
/// The pairing is a fact, not a match: the agent stated its own identifier in the same
/// message that carried its process number, and nothing else on this machine ties the two
/// together — measured, and recorded in `DiscoveredAgentProcess`.
///
/// Worth keeping because the two halves outlive each other. A session's record leaves the
/// app's memory long before its agent stops running: the row is dismissed by hand, or swept
/// after a silence. What is left is a process, and without this pairing all it can become is
/// a row with no name, for a session whose name is sitting in its transcript the whole time.
public struct RememberedAgentProcess: Codable, Equatable, Sendable {
    public let source: AgentSource
    public let processID: Int32
    /// The other half of the process's identity, kept because macOS reuses process numbers:
    /// a pairing matched on the number alone would hand one session's name to another
    /// session's row.
    public let startedAt: Date
    /// The session's own label: its identifier put through the redaction, which is also what
    /// the name of its transcript hashes to. `docs/architecture.md` §15.
    public let sessionLabel: String

    public init(source: AgentSource, processID: Int32, startedAt: Date, sessionLabel: String) {
        self.source = source
        self.processID = processID
        self.startedAt = startedAt
        self.sessionLabel = sessionLabel
    }

    /// The run of the process this pairing is about, named the way a scan names it.
    public var processLabel: String {
        DiscoveredAgentProcess.processLabel(processID: processID, startedAt: startedAt)
    }
}

/// What one reconcile did to the rows built from processes.
public struct DiscoveredProcessChange: Equatable, Sendable {
    public let added: [SessionSnapshot]
    public let removedIDs: [String]

    public var isEmpty: Bool {
        added.isEmpty && removedIDs.isEmpty
    }
}
