import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class LampGradientTests: XCTestCase {
    func testStoredEndpointsAndCycleReachTheAnimationForEveryShape() throws {
        let preferences = try isolatedPreferences()
        let store = LampSchemeStore(preferences: preferences)
        for phase: SessionPhase in [.executing, .disconnected, .rateLimited] {
            store.setColor(NSColor(sRGB: "#00EEEC"), for: phase)
            store.setGradientColor(NSColor(sRGB: "#BF9BFA"), for: phase)
            store.setAnimationCycle(4, for: phase)
            store.setMotion(.gradient, for: phase)
            let reopened = LampSchemeStore(preferences: preferences)
            let look = SessionLamp.appearance(
                for: testSession(phase: phase, lastObservedAt: Date()), scheme: reopened.scheme)
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

    func testAnOlderSchemeKeepsItsOriginalAnimationSpeed() throws {
        let preferences = try isolatedPreferences()
        preferences.set("urgent", forKey: "lampMotion.executing")
        preferences.set("#FF0000", forKey: "lampColor.executing")
        let scheme = LampSchemeStore(preferences: preferences).scheme
        let look = SessionLamp.appearance(for: testSession(phase: .executing, lastObservedAt: Date()), scheme: scheme)
        let lamp = SessionLampView(appearance: look, diameter: 12)
        let animation = try XCTUnwrap(lamp.layer?.animation(forKey: "lamp") as? CABasicAnimation)
        XCTAssertEqual(look.color.srgbHex, "#FF0000")
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration, 0.55)
        XCTAssertEqual((animation.toValue as? NSNumber)?.floatValue, 0.55)
    }

    func testDimUsesTheChosenFullCycleForEveryShape() throws {
        let store = LampSchemeStore(preferences: try isolatedPreferences())
        for phase: SessionPhase in [.executing, .disconnected, .rateLimited] {
            store.setMotion(.dim, for: phase)
            store.setAnimationCycle(6, for: phase)
            let look = SessionLamp.appearance(
                for: testSession(phase: phase, lastObservedAt: Date()), scheme: store.scheme)
            let lamp = SessionLampView(appearance: look, diameter: 12)
            let animation = try XCTUnwrap(lamp.layer?.animation(forKey: "lamp") as? CABasicAnimation)
            XCTAssertEqual(animation.keyPath, "opacity")
            XCTAssertEqual(animation.duration, 3)
            XCTAssertTrue(animation.autoreverses)
            XCTAssertEqual(animation.repeatCount, .infinity)
        }
    }

    func testLegacyModesMigrateBeforeSeedingAndDoNotOverwriteLaterChoices() throws {
        for (oldMotion, expectedCycle) in [("pulse", 2.8), ("urgent", 1.1), ("gradient", 7.0)] {
            let preferences = try isolatedPreferences()
            preferences.set(oldMotion, forKey: "lampMotion.executing")
            preferences.set(7, forKey: "lampGradientCycle.executing")
            preferences.set("#ABCDEF", forKey: "lampGradientColor.executing")
            let store = LampSchemeStore(preferences: preferences)
            preferences.seed(store.defaultValues)
            let reopened = LampSchemeStore(preferences: preferences)
            XCTAssertEqual(reopened.scheme.style(for: .executing).motion, oldMotion == "gradient" ? .gradient : .dim)
            XCTAssertEqual(reopened.scheme.style(for: .executing).animationCycle, expectedCycle)
            XCTAssertEqual(reopened.scheme.style(for: .executing).gradientColor.srgbHex, "#ABCDEF")
            reopened.setAnimationCycle(5, for: .executing)
            XCTAssertEqual(LampSchemeStore(preferences: preferences).scheme.style(for: .executing).animationCycle, 5)
            reopened.reset()
            XCTAssertTrue(LampSchemeStore(preferences: preferences).scheme.isDefault)
        }
    }

    func testChangingMotionKeepsTheChosenGradientForTheNextTime() throws {
        let store = LampSchemeStore(preferences: try isolatedPreferences())
        store.setGradientColor(NSColor(sRGB: "#123456"), for: .executing)
        store.setAnimationCycle(7, for: .executing)
        store.setMotion(.steady, for: .executing)
        store.setMotion(.gradient, for: .executing)
        XCTAssertEqual(store.scheme.style(for: .executing).gradientColor.srgbHex, "#123456")
        XCTAssertEqual(store.scheme.style(for: .executing).animationCycle, 7)
        XCTAssertEqual(store.scheme.style(for: .idle).gradientColor.srgbHex, "#FFFFFF")
        store.reset()
        XCTAssertTrue(store.scheme.isDefault)
        XCTAssertEqual(store.scheme.style(for: .executing).animationCycle, 2.8)
    }

    func testInvalidSettingsCannotProduceAnInvalidAnimationPeriod() throws {
        let preferences = try isolatedPreferences()
        let store = LampSchemeStore(preferences: preferences)
        preferences.set("not a color", forKey: "lampGradientColor.executing")
        preferences.set("fast", forKey: "lampAnimationCycle.executing")
        XCTAssertEqual(store.scheme.style(for: .executing).gradientColor.srgbHex, "#FFFFFF")
        XCTAssertEqual(store.scheme.style(for: .executing).animationCycle, 2.8)
        for (stored, expected) in [(-1.0, 0.5), (0, 0.5), (50, 10)] {
            preferences.set(stored, forKey: "lampAnimationCycle.executing")
            XCTAssertEqual(store.scheme.style(for: .executing).animationCycle, expected)
        }
        store.setAnimationCycle(4, for: .executing)
        store.setAnimationCycle(.nan, for: .executing)
        store.setAnimationCycle(.infinity, for: .executing)
        XCTAssertEqual(store.scheme.style(for: .executing).animationCycle, 4)
    }
}
