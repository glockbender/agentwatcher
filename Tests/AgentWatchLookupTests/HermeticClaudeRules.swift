import Foundation

@testable import AgentWatchLookup

extension ClaudeSessionRegistry {
    /// A registry with nothing in it, so that a process number a test invents cannot meet the
    /// record of a real session on the machine running the tests.
    static let nothingRecorded = ClaudeSessionRegistry(
        directory: URL(fileURLWithPath: "/private/tmp/agent-watch-tests-no-session-records", isDirectory: true),
        startTime: { _ in nil }
    )
}

extension ClaudeProcessRules {
    /// Claude's rules knowing processes by their path alone.
    static let byPathAlone = ClaudeProcessRules(registry: .nothingRecorded)
}
