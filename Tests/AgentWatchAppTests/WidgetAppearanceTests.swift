import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The widget paints its own background and text, but AppKit paints a control's bezel — the
/// `×` a row keeps — in the appearance the control inherits, which is the Mac's. Under a light
/// system appearance a dark widget showed a near-black `×` on its dark bezel.
/// `testEitherCounterLeavesTheDismissMarkShowing` failed on the CI machine on every push since
/// it was written, and here only with the light appearance forced — drawn that way, the mark was
/// barely there. That the CI machine draws in the light appearance, macOS's default, is inferred
/// from this, not measured.
@MainActor
final class WidgetAppearanceTests: XCTestCase {
    func testTheListDrawsItsControlsInTheAppearanceOfItsOwnBackground() {
        let cases: [(WidgetBackground, NSAppearance.Name, NSAppearance.Name)] = [
            (.graphite, .aqua, .darkAqua),
            (.graphite, .darkAqua, .darkAqua),
            (.pearl, .darkAqua, .aqua),
            (.pearl, .aqua, .aqua),
        ]
        for (background, system, expected) in cases {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: system)
            let list = HUDSessionListView(
                models: [],
                usageLimits: [],
                now: .now,
                availableWidth: 400,
                focus: { _ in },
                remove: { _ in },
                background: background,
                lampScheme: LampScheme(),
                backgroundOpacity: 1,
                style: .standard,
                restoredScrollOffset: nil,
                onScroll: { _ in }
            )
            window.contentView = list

            XCTAssertEqual(
                list.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                expected,
                "\(background.storedName) under \(system.rawValue)"
            )
        }
    }
}
