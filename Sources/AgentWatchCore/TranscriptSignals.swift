import Foundation

/// Which of an agent's own threads a session is.
///
/// Codex gives a subagent and a review thread each their own session, so they arrive as rows
/// of their own; Claude counts a subagent's work as the parent's and shows one row. That is a
/// difference between the agents, not one this app should smooth over — a row that exists
/// deserves to say what it is.
public enum SessionThreadKind: String, Codable, Equatable, Sendable {
    case user
    case subagent
    case review
}

/// What a session says about itself in its own transcript, beyond the facts that move its
/// lifecycle.
public struct TranscriptSignals: Equatable, Sendable {
    /// The model the session is running on. The one signal both agents write: Claude names it
    /// on every assistant record, Codex on every turn.
    public var modelName: String?
    /// How hard the model was asked to think. Codex states it per turn; Claude has no
    /// equivalent in its transcript.
    public var reasoningEffort: String?
    /// Input tokens for the latest model request. Only Codex reports the window size.
    public var contextInputTokens: Int?
    public var contextWindowTokens: Int?
    /// Codex only: the branch is in the file's own opening record. Claude's branch reaches
    /// the app through the hook sender instead, which is why nothing here fills it.
    public var gitBranch: String?
    public var threadKind: SessionThreadKind?
    /// The name Codex gives a subagent thread — "Darwin", "Parfit". Not a title: the thread
    /// has one of those too, and it says what the work is rather than who is doing it.
    public var threadNickname: String?

    public init(
        modelName: String? = nil,
        reasoningEffort: String? = nil,
        contextInputTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        gitBranch: String? = nil,
        threadKind: SessionThreadKind? = nil,
        threadNickname: String? = nil
    ) {
        self.modelName = modelName
        self.reasoningEffort = reasoningEffort
        self.contextInputTokens = contextInputTokens
        self.contextWindowTokens = contextWindowTokens
        self.gitBranch = gitBranch
        self.threadKind = threadKind
        self.threadNickname = threadNickname
    }

    public var isEmpty: Bool {
        self == TranscriptSignals()
    }

    /// A later reading wins field by field, and a field the newer reading is silent about
    /// keeps what it had. One increment carries a turn's model but no token count, the next
    /// the other way round, and neither should blank what the other found.
    public func merging(_ newer: TranscriptSignals) -> TranscriptSignals {
        TranscriptSignals(
            modelName: newer.modelName ?? modelName,
            reasoningEffort: newer.reasoningEffort ?? reasoningEffort,
            contextInputTokens: newer.contextInputTokens ?? contextInputTokens,
            contextWindowTokens: newer.contextWindowTokens ?? contextWindowTokens,
            gitBranch: newer.gitBranch ?? gitBranch,
            threadKind: newer.threadKind ?? threadKind,
            threadNickname: newer.threadNickname ?? threadNickname
        )
    }

    /// Above any real context window and short of a number that would stretch a row past the
    /// width it was measured for. Anything larger is not a count, and a transcript is a file
    /// on disk that anything can write to.
    public static let maximumContextTokens = 100_000_000
}
