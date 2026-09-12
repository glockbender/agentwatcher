/// Comparing two version strings, in the one place both things that are versioned agree on.
///
/// The app and the IDE plugin are released apart and compared the same way, so the rule lives
/// here rather than twice: a second copy is how `0.1.10` ends up older than `0.1.9` in one
/// place and newer in the other.
public enum ReleaseVersion {
    /// Whether one version string names a later release than the other.
    ///
    /// Numeric part by numeric part, because `0.1.10` is later than `0.1.9` and no string
    /// comparison will say so. A part may carry a tag after its number — `0-beta`, `0-rc1` —
    /// and then the plain number is the finished build and the later of the two; two tags on
    /// one number compare as text, which is good enough for choosing between two builds.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let left = version.split(separator: ".", omittingEmptySubsequences: false).map(Part.init)
        let right = other.split(separator: ".", omittingEmptySubsequences: false).map(Part.init)
        for index in 0..<max(left.count, right.count) {
            let one = index < left.count ? left[index] : Part("")
            let two = index < right.count ? right[index] : Part("")
            guard one != two else {
                continue
            }
            return one > two
        }
        return false
    }

    /// One dot-separated part of a version: the number it starts with, and whatever follows.
    private struct Part: Equatable, Comparable {
        let number: Int?
        let tag: Substring

        init(_ text: Substring) {
            let digits = text.prefix { ("0"..."9").contains($0) }
            number = Int(digits)
            tag = text.dropFirst(digits.count)
        }

        static func < (lhs: Part, rhs: Part) -> Bool {
            switch (lhs.number, rhs.number) {
            case let (one?, two?) where one != two:
                return one < two
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            default:
                break
            }
            // The same number: the one with nothing after it is the finished build.
            if lhs.tag.isEmpty != rhs.tag.isEmpty {
                return !lhs.tag.isEmpty
            }
            return lhs.tag < rhs.tag
        }
    }
}
