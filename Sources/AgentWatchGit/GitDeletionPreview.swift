import Foundation

/// Evidence available before Mothership asks the destination for its current default branch.
public enum GitDeletionPreview: Equatable, Sendable {
    case builtIn, projectRule, includedRule, dependsOnRemote

    private static let key = "mothership.protectedBranch"

    /// Git locks the repository config for each write. Matching the exact previous value avoids
    /// replacing other branches, including concurrent edits from a second working copy.
    public static func setProjectRule(in folder: URL, branch: String, protected: Bool) throws -> Self {
        let current = try read(in: folder, branch: branch)
        switch (protected, current) {
        case (true, .dependsOnRemote):
            let result = try git(
                ["config", "--local", "--fixed-value", "--replace-all", "--", key, branch, branch], in: folder)
            guard result.status == 0 else { throw PreviewError.writeFailed }
        case (false, .projectRule):
            let result = try git(["config", "--local", "--fixed-value", "--unset-all", "--", key, branch], in: folder)
            // Another writer may already have removed the rule. Read the effective setting below.
            guard result.status == 0 || result.status == 5 else { throw PreviewError.writeFailed }
        default:
            return current
        }
        return try read(in: folder, branch: branch)
    }

    public static func read(in folder: URL, branch: String) throws -> Self {
        guard !branch.isEmpty, !branch.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw PreviewError.invalidBranch }
        let root = try git(["rev-parse", "--show-toplevel"], in: folder)
        guard root.status == 0 else { throw PreviewError.unreadableRepository }
        let format = try git(["check-ref-format", "refs/heads/" + branch], in: folder)
        if format.status == 1 { throw PreviewError.invalidBranch }
        guard format.status == 0 else { throw PreviewError.unreadableRepository }

        if branch == "main" || branch == "master" { return .builtIn }
        if try contains(branch, in: folder, includeFiles: false) { return .projectRule }
        if try contains(branch, in: folder, includeFiles: true) { return .includedRule }
        return .dependsOnRemote
    }

    private static func contains(_ branch: String, in folder: URL, includeFiles: Bool) throws -> Bool {
        let config = try git(
            ["config", "--local", includeFiles ? "--includes" : "--no-includes", "--null", "--get-all", key],
            in: folder)
        guard config.status == 0 || config.status == 1 else { throw PreviewError.unreadableRepository }
        // Git compares ref names byte for byte, including their Unicode normalization.
        return config.output.split(separator: 0).contains { $0.elementsEqual(branch.utf8) }
    }

    private enum PreviewError: LocalizedError {
        case invalidBranch, unreadableRepository, writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidBranch: "Enter a valid branch name, such as release."
            case .unreadableRepository:
                "Could not read this repository’s Git configuration. Choose a Git working folder."
            case .writeFailed: "Git could not save this project rule. Check write access and retry."
            }
        }
    }

    private static func git(_ arguments: [String], in folder: URL) throws -> GitCommand.Result {
        try GitCommand.run(arguments, in: folder)
    }
}
