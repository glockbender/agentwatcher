import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class LampSchemeTests: XCTestCase {
    func testRateLimitIsAPulsingLilacPause() {
        let look = SessionLamp.appearance(for: session(in: .rateLimited), scheme: LampScheme())
        XCTAssertEqual(look.name, "limit reached")
        XCTAssertEqual(look.shape, .pause)
        XCTAssertEqual(look.motion, .dim)
        XCTAssertEqual(look.color.srgbHex, "#BF9BFA")
        let view = SessionLampView(appearance: look, diameter: 12)
        XCTAssertTrue(view.isBlinking)
        XCTAssertNotNil(view.layer?.mask, "the pause must be drawn, not only named")
        XCTAssertEqual(view.paintedColor?.srgbHex, "#BF9BFA")
    }

    func testAnUntouchedSchemeLeavesEveryPhaseAsTheAppDrewIt() {
        let scheme = LampScheme()

        for phase in SessionPhase.allCases {
            let look = SessionLamp.appearance(for: session(in: phase), scheme: scheme)
            let builtIn = SessionLamp.builtInAppearance(for: session(in: phase))
            XCTAssertEqual(look.color, builtIn.color, "\(phase)")
            XCTAssertEqual(look.motion, builtIn.motion, "\(phase)")
            XCTAssertEqual(look.shape, builtIn.shape, "\(phase)")
            XCTAssertEqual(look.name, builtIn.name, "\(phase)")
        }
    }

    /// Every lamp has to be visible against the surface it is drawn on, which is the one
    /// thing comparing the phases against each other cannot check. `sessionClosed` was once
    /// `#000000` on the near-black Graphite: 1.35:1, a ring nobody could see.
    ///
    /// The blue default leaves six phases under 3:1 by choice — the reason is on
    /// `defaultLampStyle`. They are named here so the list changes only on purpose: a phase
    /// that newly drops below fails, and so does one that no longer needs its place.
    func testEveryLampIsVisibleAgainstTheDefaultBackgroundExceptTheOnesAcceptedByName() {
        let accepted: Set<SessionPhase> = [
            .idle, .waitingForUser, .rateLimited, .failed, .terminalClosed, .disconnected,
        ]
        let background = WidgetBackground.defaultBackground.color

        for phase in SessionPhase.allCases {
            let contrast = contrastRatio(phase.defaultLampStyle.color, background)
            let reading = "\(phase) draws at \(String(format: "%.2f", contrast)):1 on the default background"
            if accepted.contains(phase) {
                XCTAssertLessThanOrEqual(contrast, 3, "\(reading); take it off the accepted list")
            } else {
                XCTAssertGreaterThan(contrast, 3, reading)
            }
        }
    }

    func testDefaultsKeepTheSelectedPaletteAndDistinctAnimationCycles() {
        let work = SessionPhase.executing.defaultLampStyle
        XCTAssertEqual(work.color.srgbHex, "#00FF5C")
        XCTAssertEqual(work.animationCycle, 2.5)
        let attention = SessionPhase.waitingForUser.defaultLampStyle
        XCTAssertEqual(attention.motion, .gradient)
        XCTAssertEqual(attention.color.srgbHex, "#FF9F0A")
        XCTAssertEqual(attention.gradientColor.srgbHex, "#FFFB00")
        XCTAssertEqual(attention.animationCycle, 0.5)
        XCTAssertEqual(SessionPhase.planning.defaultLampStyle.animationCycle, 1.5)
        XCTAssertEqual(SessionPhase.failed.defaultLampStyle.animationCycle, 1)
    }

    /// WCAG relative luminance. Written out rather than taken from AppKit because what is
    /// being asked is how different two colours look, and no AppKit call answers that.
    private func contrastRatio(_ one: NSColor, _ other: NSColor) -> CGFloat {
        let first = relativeLuminance(one)
        let second = relativeLuminance(other)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else {
            return 0
        }
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }

    private func session(in phase: SessionPhase) -> SessionSnapshot {
        testSession(phase: phase, lastObservedAt: Date(timeIntervalSince1970: 1_000))
    }
}

/// The settings window offers one row per phase, and each row has to say when the phase
/// happens. These are the two strings that row is built from.
final class SessionPhaseWordingTests: XCTestCase {
    func testEveryPhaseIsNamedAndExplained() {
        for phase in SessionPhase.allCases {
            XCTAssertFalse(phase.settingsName.isEmpty, "\(phase)")
            XCTAssertFalse(phase.explanation.isEmpty, "\(phase)")
        }
    }

    /// Guards the one mistake a copied row makes: a new phase that keeps its neighbour's
    /// wording, which the person would read as the same state listed twice.
    func testNoTwoPhasesShareWording() {
        XCTAssertEqual(Set(SessionPhase.allCases.map(\.settingsName)).count, SessionPhase.allCases.count)
        XCTAssertEqual(Set(SessionPhase.allCases.map(\.explanation)).count, SessionPhase.allCases.count)
    }
}
