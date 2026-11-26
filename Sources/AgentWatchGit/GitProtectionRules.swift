import Foundation

public enum GitBranchOperation: String, CaseIterable, Identifiable, Sendable {
    case push, forcePush, delete

    public var id: Self { self }

    public var defaultLevel: GitCheckLevel {
        switch self {
        case .push: .none
        case .forcePush: .name
        case .delete: .click
        }
    }
}

/// Shared with AgentWatchGit. Version 1 applied each type to both editable operations.
public struct GitProtectionRules: Codable, Equatable, Sendable {
    public struct Rules: Codable, Equatable, Sendable {
        public var forcePush: [GitBranchType] = []
        public var delete: [GitBranchType] = []

        public init() {}

        public subscript(operation: GitBranchOperation) -> [GitBranchType] {
            get {
                switch operation {
                case .push: []
                case .forcePush: forcePush
                case .delete: delete
                }
            }
            set {
                switch operation {
                case .push: break
                case .forcePush: forcePush = newValue
                case .delete: delete = newValue
                }
            }
        }
    }

    public static let fileName = GitBranchTypes.fileName
    private static let maxBytes = 1024 * 1024
    private let version: Int
    public var enabled: Bool
    public var global: Rules
    public var repositories: [String: Rules]

    public init() {
        version = 2
        enabled = true
        global = Rules()
        repositories = [:]
    }

    public static func load(from url: URL) throws -> Self {
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return Self()
        }
        defer { try? file.close() }
        let data = try file.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        let decoder = JSONDecoder()
        switch try decoder.decode(Version.self, from: data).version {
        case 1:
            let old = try decoder.decode(GitBranchTypes.self, from: data)
            var rules = Self()
            rules.global.forcePush = old.types
            // The editor uses the rule ID to locate changes. Each operation owns its copy.
            rules.global.delete = old.types.map { GitBranchType(name: $0.name, patterns: $0.patterns, level: $0.level) }
            return rules
        case 2:
            return try decoder.decode(Self.self, from: data)
        case let version:
            throw GitBranchTypes.TableError.unknownVersion(version)
        }
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func level(
        for operation: GitBranchOperation, branch: String, repository: String?
    ) -> (level: GitCheckLevel, source: String?) {
        func match(_ rules: [GitBranchType]) -> GitBranchType? {
            rules.first { $0.patterns.contains { GitBranchTypes.matches(pattern: $0, name: branch) } }
        }
        let globalRule = match(global[operation])
        let level = globalRule?.level ?? operation.defaultLevel
        if let repository, let rules = repositories[repository], let local = match(rules[operation]),
            local.level > level
        {
            return (local.level, local.name)
        }
        return (level, globalRule?.name)
    }

    private struct Version: Decodable { let version: Int }

    private enum Failure: LocalizedError {
        case tooLarge

        var errorDescription: String? { "The Git protection rules file is too large (maximum 1 MB)." }
    }
}

public struct GitProtectionRepository: Equatable, Sendable {
    public let folder: URL
    public let key: String

    public init(folder: URL) throws {
        let result = try GitCommand.run(["rev-parse", "--git-common-dir"], in: folder)
        guard result.status == 0, var path = String(data: result.output, encoding: .utf8)
        else { throw Failure.invalidRepository }
        if path.hasSuffix("\n") { path.removeLast() }
        guard !path.isEmpty else { throw Failure.invalidRepository }
        let directory =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : folder.appendingPathComponent(path, isDirectory: true)
        self.folder = folder
        key = directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private enum Failure: LocalizedError {
        case invalidRepository

        var errorDescription: String? { "Choose a folder in a Git repository." }
    }
}
