import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class LampGradientTests: XCTestCase {
    func testStoredEndpointsAndCycleReachTheAnimationForEveryShape() throws {
        for phase: SessionPhase in [.executing, .disconnected, .rateLimited] {
            let scheme = LampScheme(styles: [
                phase: LampStyle(
                    color: NSColor(sRGB: "#00EEEC"), motion: .gradient,
                    gradientColor: NSColor(sRGB: "#BF9BFA"), animationCycle: 4)
            ])
            let look = SessionLamp.appearance(
                for: testSession(phase: phase, lastObservedAt: Date()), scheme: scheme)
            let lamp = SessionLampView(appearance: look, diameter: 12)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView?.addSubview(lamp)
            let animation = try XCTUnwrap(lamp.layer?.animation(forKey: "lamp") as? CABasicAnimation)
            XCTAssertEqual(animation.keyPath, phase == .disconnected ? "borderColor" : "backgroundColor")
            XCTAssertEqual(animation.duration, 2)
            XCTAssertTrue(animation.autoreverses)
            XCTAssertEqual(animation.repeatCount, .infinity)
            XCTAssertEqual(lamp.layer?.opacity, 1, "color fades do not fade the whole lamp out")
            XCTAssertTrue(CFEqual(try XCTUnwrap(animation.fromValue) as AnyObject, NSColor(sRGB: "#00EEEC").cgColor))
            XCTAssertTrue(CFEqual(try XCTUnwrap(animation.toValue) as AnyObject, NSColor(sRGB: "#BF9BFA").cgColor))
        }
    }

    func testNoneAndEqualColorsDoNotScheduleAnyAnimation() throws {
        for phase: SessionPhase in [.executing, .disconnected, .rateLimited] {
            for motion: SessionLampAppearance.Motion in [.steady, .gradient] {
                let scheme = LampScheme(styles: [
                    phase: LampStyle(
                        color: NSColor(sRGB: "#123456"), motion: motion,
                        gradientColor: NSColor(sRGB: motion == .steady ? "#FFFFFF" : "#123456"))
                ])
                let lamp = SessionLampView(
                    appearance: SessionLamp.appearance(
                        for: testSession(phase: phase, lastObservedAt: Date()), scheme: scheme), diameter: 12)
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView?.addSubview(lamp)
                XCTAssertTrue(lamp.layer?.animationKeys()?.isEmpty ?? true)
                XCTAssertFalse(lamp.isBlinking)
                XCTAssertEqual(lamp.paintedColor?.srgbHex, "#123456")
            }
        }
    }

    func testDimUsesTheChosenFullCycleForEveryShape() throws {
        for phase: SessionPhase in [.executing, .disconnected, .rateLimited] {
            let scheme = LampScheme(styles: [
                phase: LampStyle(color: phase.defaultLampStyle.color, motion: .dim, animationCycle: 6)
            ])
            let look = SessionLamp.appearance(
                for: testSession(phase: phase, lastObservedAt: Date()), scheme: scheme)
            let lamp = SessionLampView(appearance: look, diameter: 12)
            let animation = try XCTUnwrap(lamp.layer?.animation(forKey: "lamp") as? CABasicAnimation)
            XCTAssertEqual(animation.keyPath, "opacity")
            XCTAssertEqual(animation.duration, 3)
            XCTAssertTrue(animation.autoreverses)
            XCTAssertEqual(animation.repeatCount, .infinity)
        }
    }

    /// A theme file is meant to be corrected by hand, so an unreadable colour or a cycle out
    /// of range is a real input: the phase's own value answers the first, the range the second.
    func testAThemesUnreadableLampCannotProduceAnInvalidAnimationPeriod() {
        for (stored, expected) in [(-1.0, 0.5), (0, 0.5), (50, 10), (.nan, 2.5)] {
            var look = WidgetTheme.standard.dark
            look.lamps[SessionPhase.executing.rawValue] = WidgetTheme.Lamp(
                color: "#FF0000", motion: "dim", fadeTo: "not a color", cycle: stored)
            let style = look.lampScheme.style(for: .executing)
            XCTAssertEqual(style.animationCycle, expected, "\(stored)")
            XCTAssertEqual(style.gradientColor.srgbHex, "#00A900")
        }
    }
}
