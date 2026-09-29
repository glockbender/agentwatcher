import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import XCTest

@testable import AgentWatchApp

/// The question a click on a broken session puts over the widget, and the two answers.
///
/// Asked for on 2026-09-30, after the click that marked such a row and the next click that
/// ended its agent were found confusing: one click, one question, and nothing ends unless the
/// answer is yes.
@MainActor
final class EndAgentDialogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let ending = ClosedTerminalEnding.discardOutput(devicePath: "/dev/ttys012")

    func testAClickOnABrokenSessionAsksOverTheWholeWidget() throws {
        var ended: [String] = []
        let (controller, broken) = try makeController(ended: { ended.append($0) })

        try click(broken, in: controller)

        let dialog = try XCTUnwrap(controller.visibleDialog, "the click asked nothing")
        XCTAssertEqual(dialog.sessionID, broken.id)
        let widget = try XCTUnwrap(dialog.superview)
        widget.layoutSubtreeIfNeeded()
        XCTAssertEqual(dialog.frame, widget.bounds, "the question covers the whole widget")
        XCTAssertEqual(ended, [], "a click alone ends nothing")
        controller.shutdown()
    }

    func testNoLeavesEverythingAsItWas() throws {
        var ended: [String] = []
        let (controller, broken) = try makeController(ended: { ended.append($0) })
        try click(broken, in: controller)

        try XCTUnwrap(controller.visibleDialog).cancelButton.performClick(nil)

        XCTAssertNil(controller.visibleDialog)
        XCTAssertEqual(ended, [])
        XCTAssertNotNil(controller.currentRow(for: broken.id), "the row is still there")
        controller.shutdown()
    }

    func testYesEndsTheAgentOfTheSessionThatWasClicked() throws {
        var ended: [String] = []
        let (controller, broken) = try makeController(ended: { ended.append($0) })
        try click(broken, in: controller)

        try XCTUnwrap(controller.visibleDialog).endButton.performClick(nil)

        XCTAssertEqual(ended, [broken.id])
        XCTAssertNil(controller.visibleDialog)
        controller.shutdown()
    }

    func testClickingTheSameSessionAgainAsksAgain() throws {
        let (controller, broken) = try makeController(ended: { _ in })
        try click(broken, in: controller)
        try XCTUnwrap(controller.visibleDialog).cancelButton.performClick(nil)

        try click(broken, in: controller)

        XCTAssertEqual(controller.visibleDialog?.sessionID, broken.id)
        controller.shutdown()
    }

    /// A question about a session that has since gone, or come back to its terminal, is no
    /// longer the question.
    func testTheQuestionClosesWhenItsSessionIsNoLongerBroken() throws {
        let (controller, broken) = try makeController(ended: { _ in })
        try click(broken, in: controller)

        var recovered = broken
        recovered.phase = .idle
        controller.render(WidgetState(sessions: [recovered]))
        XCTAssertNil(controller.visibleDialog, "it came back to its terminal")

        controller.render(WidgetState(sessions: [broken]))
        try click(broken, in: controller)
        controller.render(WidgetState(sessions: []))
        XCTAssertNil(controller.visibleDialog, "it went")
        controller.shutdown()
    }

    /// The rows' own tracking goes on under the dialog; a card over it would read as part of
    /// the question.
    func testNoHoverCardOpensOverTheQuestion() throws {
        let (controller, broken) = try makeController(ended: { _ in })
        try click(broken, in: controller)
        let row = try XCTUnwrap(controller.currentRow(for: broken.id))

        controller.hoverChanged(row, isInside: true)
        controller.showHoverCard(for: broken.id)

        XCTAssertNil(controller.visibleHoverCardText)
        controller.shutdown()
    }

    /// A press anywhere on the widget but a button belongs to the dialog, so it can reach
    /// neither the row under it nor the start of a move.
    func testOnlyTheButtonsTakeAPress() throws {
        let dialog = try laidOutDialog(size: NSSize(width: 420, height: 300))

        XCTAssertTrue(dialog.hitTest(NSPoint(x: 5, y: 5)) === dialog)
        let end = dialog.endButton.convert(
            NSPoint(x: dialog.endButton.bounds.midX, y: dialog.endButton.bounds.midY), to: dialog)
        XCTAssertTrue(dialog.hitTest(end) === dialog.endButton)
        XCTAssertFalse(dialog.mouseDownCanMoveWindow)
        XCTAssertTrue(dialog.endButton.acceptsFirstMouse(for: nil), "the panel is never key")
    }

    /// The smallest widget, at every size on offer, takes the one line over the buttons, and
    /// everything in it stays inside the widget and clear of everything else.
    func testTheQuestionFitsTheSmallestWidgetAtEverySize() throws {
        for scale in WidgetSettingsStore.offeredScales {
            let style = WidgetStyle(scale: scale)
            let dialog = try laidOutDialog(size: style.minimumWindowSize, style: style)
            let percent = Int(scale * 100)

            XCTAssertTrue(dialog.isCompact, "at \(percent)%")
            let parts = visibleParts(of: dialog)
            for (index, part) in parts.enumerated() {
                XCTAssertTrue(dialog.bounds.contains(part), "at \(percent)% \(part) leaves the widget")
                for other in parts[(index + 1)...] {
                    XCTAssertFalse(part.intersects(other), "at \(percent)% \(part) and \(other) meet")
                }
            }
        }
    }

    /// Reported on 2026-09-30 from a screen of one pixel per point: the question's text was
    /// soft. Centring by halves put the card, and everything on it, between two pixels; a
    /// line of text that starts half a pixel off is drawn across both.
    func testEveryPartOfTheQuestionStandsOnWholePoints() throws {
        for size in [NSSize(width: 331, height: 173), NSSize(width: 340, height: 200), NSSize(width: 207, height: 57)] {
            for scale in WidgetSettingsStore.offeredScales {
                let dialog = try laidOutDialog(size: size, style: WidgetStyle(scale: scale))
                for part in visibleParts(of: dialog) {
                    XCTAssertEqual(part, part.integral, "at \(Int(scale * 100))% in \(size), \(part) is between pixels")
                }
            }
        }
    }

    func testARoomyWidgetExplainsAndNamesTheSession() throws {
        let dialog = try laidOutDialog(size: NSSize(width: 420, height: 300))

        XCTAssertFalse(dialog.isCompact)
        XCTAssertEqual(visibleParts(of: dialog).count, 4, "a heading, a sentence and two buttons")
        XCTAssertTrue(HUDEndAgentDialog.explanation(naming: "Документация проекта").contains("“Документация проекта”"))
        XCTAssertTrue(HUDEndAgentDialog.explanation(naming: nil).hasPrefix("This session"))
    }

    // MARK: - Scaffolding

    private func click(_ session: SessionSnapshot, in controller: HUDPanelController) throws {
        XCTAssertTrue(try XCTUnwrap(controller.currentRow(for: session.id)).accessibilityPerformPress())
    }

    private func makeController(
        ended: @escaping (String) -> Void
    ) throws -> (HUDPanelController, SessionSnapshot) {
        let preferences = try isolatedPreferences()
        let frameStore = HUDFrameStore(preferences: preferences)
        preferences.seed(frameStore.defaultValues)
        let controller = HUDPanelController(
            reach: { [ending] _ in .closedTerminal(ending) },
            focus: { [ending] snapshot in snapshot.phase == .terminalClosed ? .asksToEndAgent(ending) : .raised },
            remove: { _ in },
            endAgent: ended,
            background: .graphite,
            lampScheme: LampScheme(),
            backgroundOpacity: 1,
            frameStore: frameStore,
            settings: WidgetSettingsStore(preferences: preferences),
            rowLayouts: RowLayoutStore(preferences: preferences)
        )
        controller.showWindow(nil)
        let broken = testSession(index: 0, title: "Документация проекта", phase: .terminalClosed, lastObservedAt: now)
        controller.render(WidgetState(sessions: [broken]))
        return (controller, broken)
    }

    private func laidOutDialog(size: NSSize, style: WidgetStyle = .standard) throws -> HUDEndAgentDialog {
        let dialog = HUDEndAgentDialog(
            sessionID: "claude:session-0", sessionName: "Документация проекта", style: style,
            onCancel: {}, onEnd: {})
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = dialog
        dialog.layoutSubtreeIfNeeded()
        return dialog
    }

    /// The frame of every label and button showing, in the dialog's own coordinates.
    private func visibleParts(of dialog: HUDEndAgentDialog) -> [NSRect] {
        func leaves(_ view: NSView) -> [NSView] {
            view.subviews.filter { !$0.isHidden }.flatMap { $0 is NSTextField || $0 is NSButton ? [$0] : leaves($0) }
        }
        return leaves(dialog).map { $0.convert($0.bounds, to: dialog) }
    }
}
