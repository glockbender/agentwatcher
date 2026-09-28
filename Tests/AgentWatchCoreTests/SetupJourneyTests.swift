import AgentWatchCore
import XCTest

final class SetupJourneyTests: XCTestCase {
    func testChooseBackAndChooseAnotherAgent() {
        var journey = SetupJourney()
        XCTAssertEqual(journey.step, .choose)
        journey.choose(.claude)
        XCTAssertEqual(journey.step, .connect)
        journey.back()
        journey.choose(.codex)
        XCTAssertEqual(journey.source, .codex)
        XCTAssertEqual(journey.step, .connect)
    }

    func testOnlyCompleteHooksPermitVerification() {
        for hooks: ToolingInstallationState in [
            .absent, .incomplete(missing: ["Stop"]), .stale(senderPaths: ["gone"]), .unreadable,
        ] {
            var journey = SetupJourney()
            journey.choose(.claude)
            journey.continueToVerification(hooks: hooks)
            XCTAssertEqual(journey.step, .connect)
        }
        for hooks: ToolingInstallationState in [.unheard, .installed] {
            var journey = SetupJourney()
            journey.choose(.codex)
            journey.continueToVerification(hooks: hooks)
            XCTAssertEqual(journey.step, .verify)
        }
    }

    func testDeliveryCannotSkipChoiceOrConnection() {
        var journey = SetupJourney()
        journey.continueToVerification(hooks: .installed)
        journey.observe(hooks: .installed, receivedEvent: true)
        XCTAssertEqual(journey.step, .choose)
        journey.choose(.claude)
        journey.observe(hooks: .installed, receivedEvent: true)
        XCTAssertEqual(journey.step, .connect)
    }

    func testReadyRequiresBothCompleteInstallationAndDelivery() {
        var journey = SetupJourney()
        journey.choose(.codex)
        journey.continueToVerification(hooks: .unheard)
        journey.observe(hooks: .unheard, receivedEvent: false)
        XCTAssertEqual(journey.step, .verify)
        journey.observe(hooks: .installed, receivedEvent: false)
        XCTAssertEqual(journey.step, .verify)
        journey.observe(hooks: .incomplete(missing: ["Stop"]), receivedEvent: true)
        XCTAssertEqual(journey.step, .verify)
        journey.observe(hooks: .installed, receivedEvent: true)
        XCTAssertEqual(journey.step, .ready)
        journey.observe(hooks: .absent, receivedEvent: true)
        XCTAssertEqual(journey.step, .verify)
        journey.back()
        XCTAssertEqual(journey.step, .connect)
    }

    func testRestartForgetsOnlyNavigation() {
        var journey = SetupJourney()
        journey.choose(.claude)
        journey.continueToVerification(hooks: .installed)
        journey.observe(hooks: .installed, receivedEvent: true)
        journey.back()
        XCTAssertEqual(journey.step, .connect)
        journey = SetupJourney()
        XCTAssertEqual(journey.step, .choose)
        XCTAssertNil(journey.source)
    }
}
