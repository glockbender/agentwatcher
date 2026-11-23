import Foundation

/// How a force push or a remote deletion of a branch is checked, weakest first.
public enum GitCheckLevel: String, Codable, CaseIterable, Comparable, Sendable {
    /// No window: the agent's own `git push` goes through.
    case none
    /// One confirmation.
    case click
    /// Confirmation plus typing the repository name.
    case name
    /// Always refused; the person runs the command from a terminal.
    case forbid

    private var rank: Int {
        switch self {
        case .none: 0
        case .click: 1
        case .name: 2
        case .forbid: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// A named group of branches, chosen by glob patterns on the branch name.
public struct GitBranchType: Codable, Identifiable, Sendable {
    /// Only for SwiftUI lists; the file has no identity for a type but its place.
    public var id = UUID()
    public var name: String
    public var patterns: [String]
    public var level: GitCheckLevel

    public init(name: String, patterns: [String], level: GitCheckLevel) {
        self.name = name
        self.patterns = patterns
        self.level = level
    }

    private enum CodingKeys: String, CodingKey {
        case name, patterns, level
    }
}

extension GitBranchType: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.patterns == rhs.patterns && lhs.level == rhs.level
    }
}

/// The table of branch types the app writes and `AgentWatchGit` reads, one for all repositories.
///
/// The Rust side reads `~/Library/Application Support/AgentWatch/git-branch-types.json` through
/// `HOME` and treats an unreadable file as no types; it lowers nothing below the floor of
/// ADR-0025, whatever the file says.
public struct GitBranchTypes: Codable, Equatable, Sendable {
    public static let fileName = "git-branch-types.json"
    public static let currentVersion = 1

    public var version = currentVersion
    public var types: [GitBranchType]

    public init(types: [GitBranchType] = []) {
        self.types = types
    }

    /// A missing file is an empty table. Anything else that cannot be read is an error, so
    /// the settings page can say so instead of silently showing no types.
    public static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Self()
        }
        let table = try JSONDecoder().decode(Self.self, from: data)
        guard table.version == currentVersion else { throw TableError.unknownVersion(table.version) }
        return table
    }

    /// Written whole, through a temporary file, so a reader never sees half a table.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The first type with a pattern that matches the short branch name.
    public func matching(_ branch: String) -> GitBranchType? {
        types.first { type in type.patterns.contains { Self.matches(pattern: $0, name: branch) } }
    }

    /// `*` matches any run of characters, `/` included; `?` matches one character; everything
    /// else matches itself. Compared by Unicode scalar, as the Rust side compares `char`s.
    public static func matches(pattern: String, name: String) -> Bool {
        let pattern = Array(pattern.unicodeScalars)
        let name = Array(name.unicodeScalars)
        var p = 0
        var n = 0
        var star: (pattern: Int, name: Int)?
        while n < name.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == name[n] {
                p += 1
                n += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = (p, n)
                p += 1
            } else if let last = star {
                p = last.pattern + 1
                n = last.name + 1
                star = (last.pattern, last.name + 1)
            } else {
                return false
            }
        }
        return pattern[p...].allSatisfy { $0 == "*" }
    }

    public enum TableError: LocalizedError, Equatable {
        case unknownVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unknownVersion(let version):
                "The branch types file has version \(version), which this Agent Watch cannot read."
            }
        }
    }
}
