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

    func testAColourChosenForOnePhaseSurvivesAndTheOthersKeepTheirDefaults() throws {
        let preferences = try isolatedPreferences()
        let store = LampSchemeStore(preferences: preferences)

        store.setColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), for: .executing)

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

    func testStoppingTheBlinkSurvivesAndLeavesTheColourAtItsDefault() throws {
        let preferences = try isolatedPreferences()

        LampSchemeStore(preferences: preferences).setMotion(.steady, for: .planning)

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

    /// A reset writes the defaults rather than removing the keys, so the file keeps saying
    /// what the lamp is in the same shape as before.
    func testResetWritesTheDefaultsBackIntoTheFile() throws {
        let preferences = try isolatedPreferences()
        let store = LampSchemeStore(preferences: preferences)
        store.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), for: .idle)
        store.setMotion(.urgent, for: .completed)

        store.reset()

        XCTAssertTrue(LampSchemeStore(preferences: preferences).scheme.isDefault)
        for phase in SessionPhase.allCases {
            XCTAssertEqual(
                preferences.string(forKey: "lampColor.\(phase.rawValue)"),
                phase.defaultLampStyle.color.srgbHex,
                "\(phase) has to be written, not missing"
            )
            XCTAssertEqual(
                preferences.string(forKey: "lampMotion.\(phase.rawValue)"),
                phase.defaultLampStyle.motion.rawValue,
                "\(phase) has to be written, not missing"
            )
        }
    }

    func testTheDefaultsCoverEveryPhaseAndBothOfItsFields() {
        let defaults = LampSchemeStore(preferences: PreferenceFile(directoryURL: nil)).defaultValues

        XCTAssertEqual(defaults.count, SessionPhase.allCases.count * 2)
        for phase in SessionPhase.allCases {
            XCTAssertNotNil(defaults["lampColor.\(phase.rawValue)"], "\(phase)")
            XCTAssertNotNil(defaults["lampMotion.\(phase.rawValue)"], "\(phase)")
        }
    }

    func testEveryWriteTellsTheOneListener() throws {
        let store = LampSchemeStore(preferences: try isolatedPreferences())
        var changed: [WidgetSetting] = []
        store.onChange = { changed.append($0) }

        store.setColor(.systemRed, for: .idle)
        store.setMotion(.steady, for: .idle)
        store.reset()

        XCTAssertEqual(changed, [.lampScheme, .lampScheme, .lampScheme])
    }
}
