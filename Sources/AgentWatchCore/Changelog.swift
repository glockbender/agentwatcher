/// The part of `CHANGELOG.md` a person has not read yet: what changed between the version they
/// run and the one they are offered.
///
/// The update window carries the whole file, because the feed has one entry and that entry
/// cannot know which version will read it. Cutting it down happens here, on the machine that
/// knows: somebody who skipped two releases sees both, somebody one behind sees one.
public enum Changelog {
    /// The sections newer than `installed` and no newer than `offered`, newest first, exactly as
    /// the file writes them. `nil` when no section qualifies — the caller then shows what it
    /// would have shown without this, rather than an empty window.
    ///
    /// A section starts at a `## [version]` heading and runs to the next `## ` heading.
    /// `[Unreleased]` and anything before the first section are never shown: neither describes
    /// a build anybody can install.
    public static func unseen(in text: String, installed: String, offered: String) -> String? {
        let isUnseen = { (version: String) in
            ReleaseVersion.isNewer(version, than: installed) && !ReleaseVersion.isNewer(version, than: offered)
        }
        var kept: [String] = []
        var keeping = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                keeping = sectionVersion(of: line).map(isUnseen) ?? false
            }
            if keeping {
                kept.append(line)
            }
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// `0.4.0` out of `## [0.4.0] - 2026-10-12`; nothing for `## [Unreleased]` or a heading that
    /// names no version.
    private static func sectionVersion(of heading: String) -> String? {
        guard
            let open = heading.firstIndex(of: "["),
            let close = heading[open...].firstIndex(of: "]")
        else {
            return nil
        }
        let name = heading[heading.index(after: open)..<close]
        guard let first = name.first, first.isNumber else {
            return nil
        }
        return String(name)
    }
}
