import Foundation

/// What Claude Code's own record of one of its processes says that session is doing.
///
/// The record is `~/.claude/sessions/<pid>.json`, the same file `BackgroundSessionAttach`
/// reads a job identifier out of. Undocumented, like everything else in it, so every field is
/// answered with nothing rather than with a guess when it is missing or shaped unexpectedly.
///
/// It earns its place here by reporting the one moment nothing else does: a person answering
/// a dialog. No hook fires for it — the catalogue of Claude Code 2.1.272 holds 33 events and
/// none of them is the answer — and the transcript writes nothing between the call's record
/// and its result. So a row waiting on an approved call kept claiming "approval needed" for
/// as long as that call then ran: measured on this machine, 89 seconds for a `git push`
/// answered at once.
///
/// The record also carries `waitingFor` — `permission prompt` for a request to run something,
/// `input needed` for a question, and a few others. It is deliberately not read: nothing here
/// would do anything with it, and a field crossing into this app with no reader is surface
/// with no benefit. Its values are written down in `docs/agent-integration.md` §1б instead.
public struct ClaudeSessionStatus: Equatable, Sendable {
    /// The four words Claude Code writes, spelled as it spells them.
    ///
    /// Only `waiting` carries meaning here — the rest are "no dialog is up" and are kept
    /// apart because they are what the record says, and collapsing them into a `Bool` would
    /// throw away the difference for the next reader of this file.
    public enum State: String, Equatable, Sendable {
        case busy
        case idle
        case waiting
        case shell
    }

    public let state: State
    /// When the state last changed. Claude Code moves it only when the word itself changes,
    /// which is what makes it usable as the moment of the answer rather than a heartbeat.
    public let updatedAt: Date

    public init(state: State, updatedAt: Date) {
        self.state = state
        self.updatedAt = updatedAt
    }

    /// One such record, or nothing at all.
    ///
    /// `nil` for anything this app cannot read with certainty — no file, a half-written one,
    /// a word not in the four, a missing timestamp. The file belongs to another product and
    /// nothing promises its shape, so an unreadable record has to mean "nothing was learned"
    /// rather than a guess: the only thing this type can do is *end* a wait, and ending one
    /// on a misread would hide the very signal the widget exists to deliver.
    ///
    /// The file's location is `BackgroundSessionAttach.sessionRecordURL`, which already names
    /// it for the job identifier this app reads out of the same record.
    public init?(sessionRecord data: Data) {
        guard
            let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let word = document["status"] as? String,
            let state = State(rawValue: word),
            // Milliseconds since the epoch, as Claude Code writes every time in this file.
            let updatedAtMilliseconds = document["statusUpdatedAt"] as? Double
        else {
            return nil
        }
        self.state = state
        self.updatedAt = Date(timeIntervalSince1970: updatedAtMilliseconds / 1000)
    }
}
