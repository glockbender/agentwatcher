import AgentWatchCore
import Foundation

/// The row's template as it is kept between launches.
///
/// One key per field, spelled out rather than nested, for the reason `LampSchemeStore` gives:
/// the file is meant to be read and corrected by hand, and `rowLayout.parts` says what it is
/// without a legend. `PreferenceFile` holds a string, a number or a flag and nothing else, so
/// the order and the counter kinds are lines with commas in them.
///
/// Nothing here refuses a file. Anything unreadable falls back to what the app would have
/// drawn anyway, and `RowLayout`'s initialiser repairs the rest — see ADR-0011.
final class RowLayoutStore: PreferenceDefaults {
    /// The flag this store replaces. Read once, on the launch that fills in the template, and
    /// never written — see `defaultValues`.
    private static let retiredTopicKey = "showsSessionTopic"

    private enum Key {
        static let parts = "rowLayout.parts"
        static let flexible = "rowLayout.flexible"
        static let nameStyle = "rowLayout.nameStyle"
        static let modelStyle = "rowLayout.modelStyle"
        static let contextStyle = "rowLayout.contextStyle"
        static let counterKinds = "rowLayout.counterKinds"
        static let reservesDismissColumn = "rowLayout.reservesDismissColumn"
    }

    private let preferences: PreferenceFile

    /// Told after every write, like the other preference stores.
    var onChange: ((WidgetSetting) -> Void)?

    init(preferences: PreferenceFile) {
        self.preferences = preferences
    }

    var layout: RowLayout {
        guard let spelled = preferences.string(forKey: Key.parts) else {
            return .standard
        }
        // A part this version does not know is dropped rather than refused: a file written by
        // a later one must still produce a widget.
        let parts = spelled.split(separator: ",").compactMap { RowPart(rawValue: trimmed($0)) }
        guard !parts.isEmpty else {
            return .standard
        }
        let kinds = preferences.string(forKey: Key.counterKinds)
            .map { Set($0.split(separator: ",").compactMap { ActivityKind(rawValue: trimmed($0)) }) }
        return RowLayout(
            parts: parts,
            flexible: preferences.string(forKey: Key.flexible).flatMap(RowPart.init(rawValue:)),
            counterKinds: kinds ?? Set(ActivityKind.allCases),
            nameStyle: read(Key.nameStyle, RowLayout.NameStyle.init(rawValue:)) ?? .fallback,
            modelStyle: read(Key.modelStyle, RowLayout.ModelStyle.init(rawValue:)) ?? .plain,
            contextStyle: read(Key.contextStyle, RowLayout.ContextStyle.init(rawValue:)) ?? .percent,
            reservesDismissColumn: preferences.flag(forKey: Key.reservesDismissColumn) ?? false
        )
    }

    /// Every key this store owns, at the value a file without them should get.
    ///
    /// This is where `showsSessionTopic` is carried over, and the seeding does the carrying:
    /// it writes only the keys a file lacks, so the old flag decides the template exactly
    /// once — on the first launch after the update — and never again. A file that already
    /// holds a template keeps it, whatever the flag beside it still says.
    var defaultValues: [String: JSONValue] {
        let showedTopic = preferences.flag(forKey: Self.retiredTopicKey) ?? true
        let layout =
            showedTopic
            ? RowLayout.standard
            : RowLayout(
                parts: RowLayout.standard.parts.filter { $0 != .name },
                flexible: RowLayout.standard.flexible
            )
        return values(of: layout)
    }

    func setLayout(_ layout: RowLayout) {
        for (key, value) in values(of: layout) {
            switch value {
            case let .string(text): preferences.set(text, forKey: key)
            case let .bool(flag): preferences.set(flag, forKey: key)
            default: break
            }
        }
        onChange?(.rowLayout)
    }

    /// The whole template as the file holds it. One place, so a value written and a value
    /// seeded cannot drift into different spellings.
    private func values(of layout: RowLayout) -> [String: JSONValue] {
        [
            Key.parts: .string(layout.parts.map(\.rawValue).joined(separator: ",")),
            // An empty string rather than a missing key: the file holds the configuration
            // whole, and "no part gives way" is a state, not an absence.
            Key.flexible: .string(layout.flexible?.rawValue ?? ""),
            Key.nameStyle: .string(layout.nameStyle.rawValue),
            Key.modelStyle: .string(layout.modelStyle.rawValue),
            Key.contextStyle: .string(layout.contextStyle.rawValue),
            // Spelled in the order the row draws them, so the line reads the way the row does
            // rather than in whatever order a set happens to iterate.
            Key.counterKinds: .string(
                ActivityKind.allCases
                    .filter(layout.counterKinds.contains)
                    .map(\.rawValue)
                    .joined(separator: ",")
            ),
            Key.reservesDismissColumn: .bool(layout.reservesDismissColumn),
        ]
    }

    private func read<Value>(_ key: String, _ make: (String) -> Value?) -> Value? {
        preferences.string(forKey: key).flatMap(make)
    }

    /// Hand-edited files have spaces after the commas. Costing nothing to allow, and the
    /// alternative is a part silently missing from somebody's row.
    private func trimmed(_ piece: Substring) -> String {
        piece.trimmingCharacters(in: .whitespaces)
    }
}
