/// Comparing two version strings, in the one place both things that are versioned agree on.
///
/// The app and the IDE plugin are released apart and compared the same way, so the rule lives
/// here rather than twice: a second copy is how `0.1.10` ends up older than `0.1.9` in one
/// place and newer in the other.
public enum ReleaseVersion {
    /// Whether one version string names a later release than the other.
    ///
    /// Numeric part by numeric part, because `0.1.10` is later than `0.1.9` and no string
    /// comparison will say so. A part that is not a number compares as text, which is what
    /// happens to `0.2.0-rc1` and is good enough for choosing between two builds.
    public static func isNewer(_ version: String, than other: String) -> Bool {
        let left = version.split(separator: ".", omittingEmptySubsequences: false)
        let right = other.split(separator: ".", omittingEmptySubsequences: false)
        for index in 0..<max(left.count, right.count) {
            let one = index < left.count ? String(left[index]) : ""
            let two = index < right.count ? String(right[index]) : ""
            guard one != two else {
                continue
            }
            if let oneNumber = Int(one), let twoNumber = Int(two) {
                return oneNumber > twoNumber
            }
            return one > two
        }
        return false
    }
}
