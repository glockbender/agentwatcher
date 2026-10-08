import AgentWatchCore
import AgentWatchTestSupport
import Foundation
import XCTest

/// The sessions every README picture is drawn with.
///
/// Invented and in English, so a picture never shows somebody's real work, and the same cast
/// in every picture, so a reader comparing two of them sees only the setting that changed.
/// `ReadmeShowcaseTests` keeps the legend whole: a phase added to the app without a row here
/// fails a test instead of quietly missing from the README.
enum ReadmeShowcase {
    static let now = Date(timeIntervalSince1970: 100_000)

    /// An ordinary afternoon: seven sessions, at least one in each of the menu bar's four
    /// states. Listed in arrival order, which is deliberately not the order of their states,
    /// so the pictures of the other orders show something move.
    static func sessions() -> [SessionSnapshot] {
        var changelog = session(0, "Tidy the changelog", .disconnected, project: "docs", secondsAgo: 3_900)
        changelog.workedOnce = true

        var dependencies = session(
            1, "Update dependencies", .completed, source: .codex, project: "web-app", secondsAgo: 240)
        dependencies.contextTelemetry = .init(totalInputTokens: 160_000, usedPercentage: 63)
        dependencies.modelName = "gpt-5.5"
        dependencies.gitBranch = "deps/october"

        var loginTest = session(2, "Fix the flaky login test", .executing, project: "checkout-api", secondsAgo: 12)
        loginTest.activities = [
            SessionActivity(id: "shell", kind: .shell, startedAt: now),
            SessionActivity(id: "agent", kind: .subagent, startedAt: now, outlivesTurn: true),
        ]
        loginTest.contextTelemetry = .init(totalInputTokens: 82_000, usedPercentage: 41)
        loginTest.modelName = "Opus 5.5"
        loginTest.gitBranch = "fix/login-test"

        var ingress = session(3, "Refactor the ingress", .failed, project: "infra", secondsAgo: 360)
        ingress.gitBranch = "ingress-v2"

        var releaseNotes = session(
            4, "Review the release notes", .waitingForUser, source: .codex, project: "web-app", secondsAgo: 95)
        releaseNotes.userInputRequestKind = .approval
        releaseNotes.modelName = "gpt-5.5"

        var searchPlan = session(5, "Plan the search index", .planning, project: "search", secondsAgo: 30)
        searchPlan.modelName = "Opus 5.5"

        var billing = session(6, "Migrate billing to v2", .waitingForChildren, project: "billing", secondsAgo: 140)
        billing.activities = [
            SessionActivity(id: "agent", kind: .subagent, startedAt: now, outlivesTurn: true)
        ]
        billing.gitBranch = "billing-v2"

        return [changelog, dependencies, loginTest, ingress, releaseNotes, searchPlan, billing]
    }

    /// The account usage the Claude status line reports, for the line under the rows.
    static let usageLimits = [
        AgentUsageLimits(source: .claude, fiveHour: .init(usedPercentage: 23), observedAt: now)
    ]

    /// One row per lamp, named by what the lamp means.
    static func legend() -> [SessionSnapshot] {
        let rows: [(String, SessionPhase)] = [
            ("Working", .executing),
            ("Planning", .planning),
            ("Waiting for a subagent", .waitingForChildren),
            ("Needs your answer", .waitingForUser),
            ("Done", .completed),
            ("Started, nothing asked yet", .idle),
            ("Failed", .failed),
            ("Usage limit reached", .rateLimited),
            ("No signal", .disconnected),
            ("Terminal closed, agent left behind", .terminalClosed),
            ("Closed", .sessionClosed),
        ]
        return rows.enumerated().map { index, row in
            var snapshot = session(index, row.0, row.1, project: "legend", secondsAgo: 10)
            if row.1 == .waitingForUser {
                snapshot.userInputRequestKind = .approval
            }
            return snapshot
        }
    }

    private static func session(
        _ index: Int,
        _ title: String,
        _ phase: SessionPhase,
        source: AgentSource = .claude,
        project: String,
        secondsAgo: TimeInterval
    ) -> SessionSnapshot {
        var snapshot = testSession(
            index: index,
            source: source,
            title: title,
            projectName: project,
            phase: phase,
            clientKind: .cli,
            lastObservedAt: now.addingTimeInterval(-secondsAgo)
        )
        snapshot.workedOnce = phase.meansTheSessionHasWorked
        return snapshot
    }
}

final class ReadmeShowcaseTests: XCTestCase {
    func testTheLegendHasARowForEveryPhase() {
        let shown = Set(ReadmeShowcase.legend().map(\.phase))
        XCTAssertEqual(shown, Set(SessionPhase.allCases), "a phase without a row in the README's legend")
    }

    func testTheAfternoonFillsEveryStateOfTheMenuBar() {
        let counts = SessionAttentionCounts(sessions: ReadmeShowcase.sessions())
        for attention in SessionAttention.counted {
            XCTAssertGreaterThan(counts.count(of: attention), 0, "no session in \(attention)")
        }
    }
}
