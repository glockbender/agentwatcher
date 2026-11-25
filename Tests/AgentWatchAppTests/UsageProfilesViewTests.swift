import AgentWatchCore
import XCTest

@testable import AgentWatchApp
@testable import AgentWatchLookup

@MainActor
final class UsageProfilesViewTests: XCTestCase {
    /// While a profile is being read for the first time the page says so, instead of saying that
    /// no quota was found; a reading already shown stays through the next read.
    func testACodexProfileSaysItIsReadingUntilTheReadEnds() throws {
        let usage = try XCTUnwrap(
            CodexProfileUsage.latest(
                inTail: Data(
                    #"{"timestamp":"2026-11-01T12:00:01Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":30,"window_minutes":300}}}}"#
                        .utf8), sessionLabel: "chat"))
        XCTAssertEqual(UsageProfilesView.codexStatus(readsTranscripts: true, usage: nil, loading: true), .reading)
        XCTAssertEqual(UsageProfilesView.codexStatus(readsTranscripts: true, usage: nil, loading: false), .none)
        XCTAssertEqual(
            UsageProfilesView.codexStatus(readsTranscripts: true, usage: usage, loading: true), .found(usage))
        XCTAssertEqual(
            UsageProfilesView.codexStatus(readsTranscripts: false, usage: usage, loading: true), .transcriptsOff)
    }
}
