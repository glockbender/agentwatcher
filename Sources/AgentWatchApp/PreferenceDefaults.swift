import AgentWatchCore

/// A store that can say what every setting it owns should be when nobody has chosen.
///
/// The settings file holds the whole configuration at all times: a fresh install has it
/// written out rather than left empty, so what the widget does is readable from the file
/// instead of from the source. Each store answers for its own keys, and `AppDelegate` asks
/// all of them once at launch.
protocol PreferenceDefaults {
    var defaultValues: [String: JSONValue] { get }
}
