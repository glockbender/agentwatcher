import AgentWatchSender
import XCTest

final class AgentProcessLocatorTests: XCTestCase {
    func testFindsClaudeProcessAmongHookShellAncestors() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "claude",
                executablePath: "/private/opaque/claude/versions/claude"
            ),
            ProcessSnapshot(processID: 300, executableName: "zsh"),
            ProcessSnapshot(processID: 200, executableName: "goland"),
        ]

        XCTAssertEqual(AgentProcessLocator.findClaudeProcessID(in: ancestors), 400)
    }

    func testDoesNotTreatAnUnrelatedAncestorAsClaude() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(processID: 300, executableName: "zsh"),
            ProcessSnapshot(processID: 200, executableName: "goland"),
        ]

        XCTAssertNil(AgentProcessLocator.findClaudeProcessID(in: ancestors))
    }

    func testDoesNotTrustAnAncestorNamedClaudeWithoutAnInstallationPath() {
        let ancestors = [
            ProcessSnapshot(processID: 400, executableName: "claude")
        ]

        XCTAssertNil(AgentProcessLocator.findClaudeProcessID(in: ancestors))
    }

    func testFindsVersionedClaudeExecutableFromItsInstallationLayout() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "2.1.257",
                executablePath: "/private/opaque/claude/versions/2.1.257"
            ),
            ProcessSnapshot(processID: 300, executableName: "zsh"),
        ]

        XCTAssertEqual(AgentProcessLocator.findClaudeProcessID(in: ancestors), 400)
    }

    func testDoesNotTreatAnArbitraryVersionedExecutableAsClaude() {
        let ancestors = [
            ProcessSnapshot(
                processID: 500,
                executableName: "2.1.257",
                executablePath: "/private/opaque/not-claude/versions/2.1.257"
            )
        ]

        XCTAssertNil(AgentProcessLocator.findClaudeProcessID(in: ancestors))
    }

    func testClassifiesClaudeHookAsCLIWithoutSendingItsHostPath() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "2.1.257",
                executablePath: "/private/opaque/claude/versions/2.1.257"
            ),
        ]

        XCTAssertEqual(AgentProcessLocator.clientKind(for: .claude, in: ancestors), .cli)
    }

    func testClassifiesCodexDesktopFromItsTrustedApplicationBundle() {
        let ancestors = [
            ProcessSnapshot(processID: 500, executableName: "sh"),
            ProcessSnapshot(
                processID: 400,
                executableName: "codex",
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex"
            ),
        ]

        XCTAssertEqual(AgentProcessLocator.clientKind(for: .codex, in: ancestors), .desktop)
    }

    func testClassifiesCodexCLIOnlyWhenTheExecutableIsNotTheDesktopBundle() {
        let ancestors = [
            ProcessSnapshot(
                processID: 400,
                executableName: "codex",
                executablePath: "/opt/homebrew/Caskroom/codex/0.140.0/codex-aarch64-apple-darwin"
            )
        ]

        XCTAssertEqual(AgentProcessLocator.clientKind(for: .codex, in: ancestors), .cli)
    }

    /// The one call here that reads the kernel's own struct rather than a list a test built,
    /// so the layout is worth exercising for real. A PID above the system's maximum belongs to
    /// nobody and never will, which is the case a naive `sysctl` gets wrong: it succeeds and
    /// fills in nothing, so only the returned size tells the two apart.
    func testAProcessStartTimeIsReadForALivePIDAndRefusedForOneNobodyHolds() throws {
        let startedAt = try XCTUnwrap(AgentProcessLocator.startTime(of: getpid()))

        XCTAssertLessThanOrEqual(startedAt, Date())
        XCTAssertGreaterThan(startedAt, Date(timeIntervalSince1970: 1_000_000_000))
        XCTAssertNil(AgentProcessLocator.startTime(of: 999_999))
    }
}
