import AgentWatchCore
import Foundation

/// One thing a row can draw.
enum RowPart: String, CaseIterable {
    case timer
    case lamp
    case agent
    case fault
    case name
    case project
    case branch
    case model
    case host
    case thread
    case counters
    case context
    /// Where the row's slack collects. Everything before it is packed to the left and
    /// everything after it sits at the right edge.
    ///
    /// Why a row needs one, measured before it was configurable: without the gap the counters
    /// followed the name, which is a different length in every row and changes with the work —
    /// so the same number appeared in each row at a different place, and moved sideways the
    /// moment a name was shortened.
    case gap

    /// Whether this part has anything to give up when the widget is too narrow for the row.
    ///
    /// Text the agent wrote, and only that. A lamp is a fixed dot, an icon a fixed box, and
    /// the timer holds three characters on purpose so the columns line up down the list —
    /// shortening any of them turns a fact into a riddle. `host` is text but never longer
    /// than `Background`, so it has nothing to give either.
    var canGiveWay: Bool {
        switch self {
        case .name, .project, .branch, .model, .thread: true
        case .timer, .lamp, .agent, .fault, .host, .counters, .context, .gap: false
        }
    }
}

/// The template one row is drawn from.
///
/// Sound by construction, the way `LampScheme` is complete by construction: the initialiser
/// repairs what it is given rather than refusing it, so nothing downstream has to ask whether
/// a template makes sense. The inputs it repairs are real — a settings file edited by hand,
/// and a file written by a version that knew parts this one does not. See ADR-0011.
struct RowLayout: Equatable {
    /// What the name part puts in a row.
    enum NameStyle: String {
        /// The agent's own name for the session, and the project it works in where the agent
        /// has not named it yet. What every row did before the row became configurable.
        case fallback
        /// The agent's name and nothing else. A session it has not named yet draws nothing
        /// here — accepted, and the label says so: see ADR-0011.
        case title
    }

    /// Whether the model part says how hard the model was asked to think. Codex only writes
    /// that, so a Claude row draws the same thing either way.
    enum ModelStyle: String {
        case plain
        case effort
    }

    /// Which of the two context numbers the row carries.
    enum ContextStyle: String {
        case percent
        case tokens
        case both
    }

    /// The parts in the order they are drawn, each appearing once, with exactly one `.gap`.
    let parts: [RowPart]
    /// The one part that narrows when the widget does, or nothing when the template holds
    /// no part that could.
    let flexible: RowPart?
    /// Which kinds of work the counter block counts.
    let counterKinds: Set<ActivityKind>
    let nameStyle: NameStyle
    let modelStyle: ModelStyle
    let contextStyle: ContextStyle
    /// Whether a row whose session is still at work holds the dismiss button's column open.
    ///
    /// The button belongs to a session that has stopped (`SessionPresence.dismissal`), so
    /// without this the right edge of a working row sits a button-width further out than a
    /// finished one's, and the counters of the two do not line up down the list.
    let reservesDismissColumn: Bool

    init(
        parts: [RowPart],
        flexible: RowPart? = nil,
        counterKinds: Set<ActivityKind> = Set(ActivityKind.allCases),
        nameStyle: NameStyle = .fallback,
        modelStyle: ModelStyle = .plain,
        contextStyle: ContextStyle = .percent,
        reservesDismissColumn: Bool = false
    ) {
        self.nameStyle = nameStyle
        self.modelStyle = modelStyle
        self.contextStyle = contextStyle
        self.reservesDismissColumn = reservesDismissColumn
        // Nothing chosen is not "count nothing": a block drawing nothing looks exactly like a
        // session with no work, and cannot say which of the two it is. Fail open, the way
        // monitoring does — somebody who wants none takes the part out of the template.
        self.counterKinds = counterKinds.isEmpty ? Set(ActivityKind.allCases) : counterKinds
        var seen: Set<RowPart> = []
        // First occurrence wins: it is where the person put the part, and a later copy only
        // pushes everything after it along. This is also what leaves one gap out of several.
        let unique = parts.filter { seen.insert($0).inserted }
        let drawn = unique.contains(.gap) ? unique : unique + [.gap]
        self.parts = drawn
        // A choice that no longer names a part of this template — or names one with nothing
        // to give up — is answered rather than refused: the first part that can give way
        // takes the job, and a template made only of fixed widths ends up with nobody in it.
        if let flexible, drawn.contains(flexible), flexible.canGiveWay {
            self.flexible = flexible
        } else {
            self.flexible = drawn.first(where: \.canGiveWay)
        }
    }

    /// The row as this app drew it before the row became configurable, and what a fresh
    /// install gets. Anyone updating finds their widget unchanged until they change it.
    static let standard = RowLayout(
        parts: [.timer, .lamp, .agent, .fault, .name, .gap, .counters, .context],
        flexible: .name
    )

    func shows(_ part: RowPart) -> Bool {
        parts.contains(part)
    }

    /// The same template with one thing changed, and everything else carried over.
    ///
    /// One place rather than a full initialiser at each control in the settings window. Three
    /// of those had already appeared, and the next field added here would have been forgotten
    /// in one of them — a setting that works from one control and silently resets from the
    /// next. The result still goes through `init`, so a change cannot skip the repairs.
    func changing(
        parts: [RowPart]? = nil,
        flexible: RowPart? = nil,
        counterKinds: Set<ActivityKind>? = nil,
        nameStyle: NameStyle? = nil,
        modelStyle: ModelStyle? = nil,
        contextStyle: ContextStyle? = nil,
        reservesDismissColumn: Bool? = nil
    ) -> RowLayout {
        RowLayout(
            parts: parts ?? self.parts,
            flexible: flexible ?? self.flexible,
            counterKinds: counterKinds ?? self.counterKinds,
            nameStyle: nameStyle ?? self.nameStyle,
            modelStyle: modelStyle ?? self.modelStyle,
            contextStyle: contextStyle ?? self.contextStyle,
            reservesDismissColumn: reservesDismissColumn ?? self.reservesDismissColumn
        )
    }
}
