import Foundation

extension SessionSnapshot {
    /// A run a program started with no window: `claude -p`, an Agent SDK run, `codex exec`.
    public var isHeadlessRun: Bool {
        clientKind == .headless
    }
}

extension Sequence where Element == SessionSnapshot {
    /// The sessions a person is shown: every one, or every one but the headless runs.
    ///
    /// A view of the sessions, not a change to them: a hidden run is still tracked and
    /// remembered, so turning the setting on shows the runs going on at that moment
    /// (ADR-0021).
    public func shown(includingHeadlessRuns: Bool) -> [SessionSnapshot] {
        includingHeadlessRuns ? Array(self) : filter { !$0.isHeadlessRun }
    }
}
