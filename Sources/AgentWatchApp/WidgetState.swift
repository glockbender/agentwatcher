import AgentWatchCore

/// Everything the widget shows, as one value.
///
/// One value rather than three properties because the widget redraws when what it shows
/// changes, and that rule can only be stated over the whole of it. The complaint used to be
/// assigned separately, which meant it could be right in the app and wrong on screen at the
/// same time — see `HUDRenderTests`.
///
/// Appearance deliberately stays out: a lamp reads its colours once when it is built, so a
/// change of scheme has to rebuild every row whatever the sessions did. Folding that into
/// the value compared here would need an escape hatch saying "redraw anyway", which is the
/// second input this type exists to remove.
struct WidgetState: Equatable {
    var sessions: [SessionSnapshot] = []
    var usageLimits: [AgentUsageLimits] = []
    /// What the widget says instead of "No active sessions" when nothing can report to it.
    ///
    /// Decided outside: the answer lives in other programs' configuration files, and reading
    /// those is not the widget's business. `nil` is the ordinary case.
    var complaint: String?
}
