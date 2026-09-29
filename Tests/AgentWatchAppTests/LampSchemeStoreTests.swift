import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

final class LampSchemeStoreTests: XCTestCase {
    func testAnEmptyFileReadsAsTheAppsOwnLamp() throws {
        let scheme = LampSchemeStore(preferences: try isolatedPreferences()).scheme

        XCTAssertTrue(scheme.isDefault)
        for phase in SessionPhase.allCases {
            XCTAssertEqual(scheme.style(for: phase).motion, phase.defaultLampStyle.motion, "\(phase)")
            XCTAssertEqual(
                scheme.style(for: phase).color.srgbHex,
                phase.defaultLampStyle.color.srgbHex,
                "\(phase)"
            )
        }
    }

    func testAColourStoredForOnePhaseIsReadAndTheOthersKeepTheirDefaults() throws {
        let preferences = try isolatedPreferences()
        preferences.set("#336699", forKey: "lampColor.executing")

        let reopened = LampSchemeStore(preferences: preferences).scheme
        XCTAssertEqual(reopened.style(for: .executing).color.srgbHex, "#336699")
        XCTAssertEqual(
            reopened.style(for: .failed).color.srgbHex,
            SessionPhase.failed.defaultLampStyle.color.srgbHex
        )
        XCTAssertEqual(
            reopened.style(for: .executing).motion,
            SessionPhase.executing.defaultLampStyle.motion,
            "choosing a colour must not change the blink"
        )
        XCTAssertFalse(reopened.isDefault)
    }

    func testAStoredSteadyMotionIsReadAndLeavesTheColourAtItsDefault() throws {
        let preferences = try isolatedPreferences()
        preferences.set("steady", forKey: "lampMotion.planning")

        let reopened = LampSchemeStore(preferences: preferences).scheme
        XCTAssertEqual(reopened.style(for: .planning).motion, .steady)
        XCTAssertEqual(
            reopened.style(for: .planning).color.srgbHex,
            SessionPhase.planning.defaultLampStyle.color.srgbHex
        )
    }

    /// The file is meant to be corrected by hand, so this is a real input, not a fault. It
    /// falls back to the default rather than to nothing, because every phase always has a
    /// lamp — there is no state in which a dot has no colour to be drawn in.
    func testAValueNobodyCanReadFallsBackToTheDefault() throws {
        let preferences = try isolatedPreferences()
        preferences.set("cornflower", forKey: "lampColor.executing")
        preferences.set("shimmer", forKey: "lampMotion.failed")

        let scheme = LampSchemeStore(preferences: preferences).scheme

        XCTAssertEqual(
            scheme.style(for: .executing).color.srgbHex,
            SessionPhase.executing.defaultLampStyle.color.srgbHex
        )
        XCTAssertEqual(scheme.style(for: .failed).motion, SessionPhase.failed.defaultLampStyle.motion)
        XCTAssertTrue(scheme.isDefault, "unreadable is not a choice")
    }
}
