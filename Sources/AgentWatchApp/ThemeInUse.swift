import AgentWatchCore

/// The theme on screen, for the drawings that are not handed one — the menu bar's marks, the
/// menu's, the widget's counters, timers and outline — and the phases the sessions are in,
/// which a state that borrows a lamp depends on. Set by the app delegate whenever the theme,
/// the system's appearance or the sessions change; read where everything is drawn. `timing`
/// is the theme's, clamped, the same in either mode.
@MainActor
enum ThemeInUse {
    static var look = WidgetTheme.standard.dark
    static var phases: [SessionPhase: Int] = [:]
    static var timing = WidgetTheme.Timing()
}
