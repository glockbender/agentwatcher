import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class LampSchemeTests: XCTestCase {
    func testAnUntouchedSchemeLeavesEveryPhaseAsTheAppDrewIt() {
        let scheme = LampScheme()

        for phase in SessionPhase.allCases {
            let look = SessionLamp.appearance(for: session(in: phase), scheme: scheme)
            let builtIn = SessionLamp.builtInAppearance(for: session(in: phase))
            XCTAssertEqual(look.color, builtIn.color, "\(phase)")
            XCTAssertEqual(look.motion, builtIn.motion, "\(phase)")
            XCTAssertEqual(look.isFilled, builtIn.isFilled, "\(phase)")
            XCTAssertEqual(look.name, builtIn.name, "\(phase)")
        }
    }

    /// Every lamp has to be visible against the surface it is drawn on, which is the one
    /// thing comparing the phases against each other cannot check.
    ///
    /// `sessionClosed` was `#000000` — a black ring on a near-black widget, at 1.35:1 where
    /// every other phase sat at 4.58:1 or better. It is the only failure this shape of
    /// mistake has, and it is invisible to a test that asks whether two phases differ.
    ///
    /// Measured against the default background alone, on purpose. The palette is built for a
    /// dark widget: `executing` reaches only 1.17:1 on the lightest background, and holding
    /// all ten to a threshold would be asserting a design decision nobody made.
    func testEveryLampIsVisibleAgainstTheDefaultBackground() {
        let background = WidgetBackground.graphite.color

        for phase in SessionPhase.allCases {
            let contrast = contrastRatio(phase.defaultLampStyle.color, background)
            XCTAssertGreaterThan(
                contrast,
                3,
                "\(phase) draws at \(String(format: "%.2f", contrast)):1 on the default background"
            )
        }
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
        SessionSnapshot(
            id: "claude:one",
            source: .claude,
            arrivalIndex: 0,
            phase: phase,
            lastObservedAt: Date(timeIntervalSince1970: 1_000)
        )
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
