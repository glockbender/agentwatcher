import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// Measures a real, laid-out row.
///
/// The rules these check are the kind that read as obviously true and are not: a label
/// truncates only against a width it was actually given, and a stack reclaims the space of
/// a hidden arranged subview. Both were wrong in the widget before, and neither shows up in
/// a test of the sizing arithmetic alone.
@MainActor
final class HUDRowLayoutTests: XCTestCase {
    private let longName = "AGENTS.md integration into CLAUDE.md and the widget layout"
    private let now = Date(timeIntervalSince1970: 5_000)

    func testACappedNameIsHeldToTheCapInsteadOfWideningTheRow() throws {
        let capped = row(titleDisplay: .truncated(toWidth: 90))
        let full = row(titleDisplay: .fullName)

        let cappedWidth = try XCTUnwrap(titleLabel(in: capped)).frame.width
        XCTAssertLessThanOrEqual(cappedWidth, 90.5, "the cap has to bind the frame, insets and all")
        XCTAssertGreaterThan(cappedWidth, 85, "and it has to use the room it was given")
        XCTAssertGreaterThan(
            try XCTUnwrap(titleLabel(in: full)).frame.width,
            120,
            "a full name is the label's own width, which for this name is far past the cap"
        )
        XCTAssertLessThan(
            capped.fittingSize.width,
            full.fittingSize.width,
            "capping the name has to narrow the row, or the widget scrolls sideways instead"
        )
    }

    func testHidingTheNameLeavesItOutOfTheRowEntirely() {
        XCTAssertNil(titleLabel(in: row(titleDisplay: .hidden)))
    }

    /// Freshness deliberately does not track `waiting for user` — a person may take an hour
    /// to answer — so nothing sweeps such a session. One that has been silent far past the
    /// disconnect threshold has to be removable by hand, or an urgent blinking lamp over a
    /// session nobody is coming back to would be permanent.
    func testASessionSilentFarTooLongCanAlwaysBeDismissed() {
        var waiting = snapshot()
        waiting.phase = .waitingForUser
        waiting.userInputRequestKind = .approval
        waiting.lastObservedAt = now.addingTimeInterval(-SessionFreshnessEvaluator.defaultDisconnectAfter - 1)

        var justAsked = snapshot()
        justAsked.phase = .waitingForUser
        justAsked.userInputRequestKind = .approval
        justAsked.lastObservedAt = now.addingTimeInterval(-30)

        XCTAssertTrue(SessionPresence.isDismissible(waiting, now: now))
        XCTAssertFalse(
            SessionPresence.isDismissible(justAsked, now: now),
            "an ordinary approval prompt is not something to offer to delete"
        )
    }

    /// The narrowest widget keeps a first letter rather than an empty space: it can be
    /// hovered, and it still tells two neighbouring rows apart.
    func testTheNarrowestRowKeepsAFirstLetter() throws {
        let laidOut = row(titleDisplay: .initial)
        let label = try XCTUnwrap(laidOut.arrangedSubviews.compactMap { $0 as? NSTextField }.last)

        XCTAssertEqual(label.stringValue, "A…")
    }

    /// One card for the whole row replaced a tooltip on each picture, so no element may keep
    /// a tooltip of its own: two things appearing on the same hover reads as a fault.
    func testNothingInARowCarriesATooltipOfItsOwn() {
        var busy = snapshot()
        busy.activities = [SessionActivity(id: "shell", kind: .shell, startedAt: now)]
        busy.contextTelemetry = .init(totalInputTokens: 85_000)

        for view in allSubviews(of: row(snapshot: busy)) {
            XCTAssertNil(view.toolTip, "\(type(of: view)) still carries a tooltip")
        }
    }

    /// The card is the only thing that explains a row, so it has to answer every question
    /// the pictures raise — and name the project and branch the row has no room for.
    func testTheHoverCardSaysEverythingTheRowCannot() {
        var session = snapshot()
        session.phase = .waitingForUser
        session.userInputRequestKind = .approval
        session.projectName = "agent-watch"
        session.gitBranch = "main"
        session.activities = [
            SessionActivity(id: "agent", kind: .subagent, startedAt: now)
        ]
        session.contextTelemetry = .init(totalInputTokens: 333_000)

        let text = hoverCardText(for: session, now: now.addingTimeInterval(90))

        XCTAssertTrue(text.contains(longName), "the whole name, whatever the row could show")
        XCTAssertTrue(text.contains("Claude Code · CLI · approval needed"))
        XCTAssertTrue(text.contains("agent-watch · main"))
        XCTAssertTrue(text.contains("Last event 1m ago"))
        XCTAssertTrue(text.contains("waiting on 1 subagent"))
        XCTAssertTrue(text.contains("333k tokens in context"))
    }

    /// A line the session cannot answer is left out, not printed empty.
    func testTheHoverCardLeavesOutWhatItDoesNotKnow() {
        var bare = snapshot()
        bare.clientKind = nil
        bare.projectName = nil
        bare.gitBranch = nil

        let lines = hoverCardText(for: bare, now: now).split(separator: "\n")

        XCTAssertEqual(lines.count, 3, "name, identity and the elapsed time — nothing else is known")
        XCTAssertFalse(lines.contains { $0.hasPrefix(" ") || $0.hasSuffix(" ·") })
    }

    /// The one thing on the card that is about the widget rather than about the session. A
    /// row that quietly stopped being watched looks exactly like a healthy quiet one, which
    /// is the failure a monitor must not have.
    func testTheHoverCardSaysWhenItHasStoppedBeingSure() {
        var faulted = snapshot()
        faulted.monitoringFault = .transcriptNotFound

        let text = hoverCardText(for: faulted, now: now)

        XCTAssertTrue(text.contains(monitoringFaultText(for: .transcriptNotFound)))
        XCTAssertFalse(text.contains("transcriptNotFound"), "words, not the name of a symbol")
    }

    /// A row the app has admitted it may be wrong about should not also make a person wait
    /// half an hour to clear it. Every other case here waits out a threshold because the app
    /// still believes what the row says.
    func testARowTheAppHasStoppedBeingSureOfCanBeDismissedAtOnce() {
        var faulted = snapshot()
        faulted.phase = .executing
        faulted.lastObservedAt = now.addingTimeInterval(-10)
        var healthy = faulted
        healthy.monitoringFault = nil
        faulted.monitoringFault = .transcriptNotFound

        XCTAssertTrue(SessionPresence.isDismissible(faulted, now: now))
        XCTAssertFalse(SessionPresence.isDismissible(healthy, now: now))
    }

    /// The one signal both agents write into their own transcript, which is what lets it be
    /// the same line in either row.
    func testTheCardNamesTheModelForEitherAgent() {
        var claude = snapshot()
        claude.modelName = "claude-opus-5"

        var codex = codexSnapshot()
        codex.modelName = "gpt-5.6-terra"
        codex.reasoningEffort = "high"

        XCTAssertTrue(hoverCardText(for: claude, now: now).contains("claude-opus-5"))
        XCTAssertTrue(hoverCardText(for: codex, now: now).contains("gpt-5.6-terra · high"))
    }

    /// Codex gives a subagent a session of its own, so it arrives as a row of its own and
    /// deserves to say what it is. A person's thread says nothing, because that is what a row
    /// is unless something says otherwise.
    func testTheCardSaysWhenARowIsAnAgentsOwnThread() {
        var subagent = codexSnapshot()
        subagent.threadKind = .subagent
        subagent.threadNickname = "Darwin"

        var ordinary = codexSnapshot()
        ordinary.threadKind = .user

        XCTAssertTrue(hoverCardText(for: subagent, now: now).contains("subagent Darwin"))
        XCTAssertNil(threadText(for: ordinary), "a person's own thread is not news")
        XCTAssertEqual(threadText(for: subagentWithoutAName()), "subagent")
    }

    private func codexSnapshot() -> SessionSnapshot {
        testSession(source: .codex, phase: .executing, clientKind: .desktop, lastObservedAt: now)
    }

    private func subagentWithoutAName() -> SessionSnapshot {
        var session = codexSnapshot()
        session.threadKind = .subagent
        return session
    }

    /// Every fault has to be sayable. A case added without wording would show a warning
    /// triangle the card could not explain.
    func testEveryFaultHasWordsAndAShortForm() {
        for fault in MonitoringFault.allCases {
            XCTAssertFalse(monitoringFaultText(for: fault).isEmpty, "\(fault) has nothing to say")
            XCTAssertFalse(monitoringFaultSummary(for: fault).isEmpty, "\(fault) has no short form")
        }
    }

    /// The menu is where a person looks to find out whether reading is happening at all, so
    /// each of the four answers has to be a different sentence.
    func testTheTranscriptMenuSaysWhichOfTheFourStatesItIsIn() {
        let summaries = [
            transcriptMenuSummary(interval: nil, isReading: false, faultedSessionCount: 0),
            transcriptMenuSummary(interval: 5, isReading: false, faultedSessionCount: 0),
            transcriptMenuSummary(interval: 5, isReading: true, faultedSessionCount: 0),
            transcriptMenuSummary(interval: 5, isReading: true, faultedSessionCount: 2),
        ]

        XCTAssertEqual(Set(summaries).count, 4, "four states, four answers")
        XCTAssertTrue(summaries[3].contains("2 sessions with a problem"))
        // Turning reading off costs more than it used to. `PostToolUse` is no longer
        // registered, so the transcript is what reports a finished tool call — and with the
        // reading off, the row keeps it until the turn ends. A person choosing "Off" has to
        // be told that, and the line that says only "not reading" does not.
        XCTAssertTrue(
            summaries[0].contains("turn"),
            "\(summaries[0]) does not say what turning it off costs"
        )
    }

    /// The tooling window is the only place a person can see how far Agent Watch got into
    /// their tooling, so each answer has to be a different sentence — and the two that mean
    /// something is wrong have to name what, not just that.
    func testTheToolingWindowSaysWhichStateEachIntegrationIsIn() {
        let hooks = ToolingHooks.hooks(for: .claude)
        let titles = [
            toolingHookStateText(state: .absent, hooks: hooks),
            toolingHookStateText(state: .installed, hooks: hooks),
            toolingHookStateText(state: .unheard, hooks: hooks),
            toolingHookStateText(state: .incomplete(missing: ["Stop"]), hooks: hooks),
            toolingHookStateText(state: .stale(senderPaths: ["/gone/AgentWatchSend"]), hooks: hooks),
            toolingHookStateText(state: .unreadable, hooks: hooks),
        ]

        XCTAssertEqual(Set(titles).count, 6, "six states, six answers")
        // The one that must not read as the line above it. Records that have never delivered
        // anything are not a working installation, and for Codex that is the ordinary state
        // until a person approves the hooks there.
        XCTAssertNotEqual(titles[2], titles[1])
        XCTAssertTrue(titles[2].contains("nothing"), "\(titles[2]) does not say what is missing")
        XCTAssertTrue(titles[3].contains("Stop"), "a missing hook is named, not counted")
        XCTAssertTrue(titles[4].contains("/gone/AgentWatchSend"), "a stale entry shows where it points")
    }

    /// The one thing the widget is allowed to ask for. With no integration at all it can show
    /// nothing and would sit empty with no explanation; with one, it never mentions the rest,
    /// because choosing only Claude on a machine that also has Codex is a decision.
    func testTheWidgetSpeaksUpOnlyWhenNothingCanReportToItAtAll() {
        XCTAssertNotNil(toolingComplaint(states: [.absent, .absent]))
        XCTAssertNil(
            toolingComplaint(states: [.installed, .absent]),
            "one integration is enough, and the others are nobody's business"
        )
        XCTAssertNil(toolingComplaint(states: [.incomplete(missing: ["Stop"]), .absent]))
        XCTAssertNil(
            toolingComplaint(states: [.installed, .unheard]),
            "one agent that has reported is enough; what the other has not done is its own business"
        )

        // Installed everywhere and heard from nowhere. The widget is empty and the advice it
        // used to give — install the hooks — is the one thing that would not help, because
        // they are installed. Codex is the common way in: the records sit there untrusted.
        let unheard = try? XCTUnwrap(toolingComplaint(states: [.unheard, .unheard]))
        XCTAssertNotEqual(unheard, toolingComplaint(states: [.absent, .absent]))
        XCTAssertNotNil(toolingComplaint(states: [.unheard, .absent]))

        // The exception, and it is a fact rather than a nag: entries that cannot run.
        let stale = try? XCTUnwrap(toolingComplaint(states: [.stale(senderPaths: ["/gone"]), .absent]))
        XCTAssertNotEqual(stale, toolingComplaint(states: [.absent, .absent]))

        // A file nobody can read comes ahead of both, because it is the one the app cannot
        // repair: the others end in a press, this one ends in a person opening a file.
        let unreadable = try? XCTUnwrap(toolingComplaint(states: [.unreadable, .absent]))
        XCTAssertNotEqual(unreadable, stale)
        XCTAssertNotEqual(unreadable, toolingComplaint(states: [.absent, .absent]))
        XCTAssertNotNil(
            toolingComplaint(states: [.unreadable, .stale(senderPaths: ["/gone"])]),
            "neither of these can report anything, so the widget still has nothing to show"
        )
    }

    /// A person's own status-line command is the thing at risk here, so the window says it
    /// will be kept before they press anything — and now shows the command itself, which is
    /// what a menu line had no room for.
    func testTheStatusLineRowPromisesToKeepACommandThatIsAlreadyThere() {
        let theirs = statusLineStateText(state: .theirs(command: "bash mine.sh"))
        XCTAssertTrue(theirs.contains("kept"))
        XCTAssertTrue(theirs.contains("bash mine.sh"), "and names the command it promises to keep")
        XCTAssertNotEqual(statusLineStateText(state: .notSet), theirs)
        XCTAssertNotEqual(statusLineStateText(state: .connected), statusLineStateText(state: .notSet))
    }

    /// The number stopped meaning "how often" when reads began following hooks: it is now a
    /// ceiling on the rate, and a menu that still promised a metronome would be wrong.
    func testTheIntervalMenuPromisesACeilingRatherThanACadence() {
        XCTAssertEqual(transcriptIntervalMenuTitle(interval: nil), "Off")
        XCTAssertEqual(transcriptIntervalMenuTitle(interval: 5), "At most every 5 seconds")
    }

    /// A transcript reports token counts and never says what they are a fraction of, so the
    /// card prints what it has instead of inventing a denominator.
    func testTheHoverCardPrintsAPercentageOnlyWhenOneIsKnown() {
        var counted = snapshot()
        counted.contextTelemetry = .init(totalInputTokens: 333_000)
        var measured = snapshot()
        measured.contextTelemetry = .init(totalInputTokens: 85_000, usedPercentage: 42.5)

        XCTAssertTrue(hoverCardText(for: counted, now: now).contains("333k tokens in context"))
        XCTAssertFalse(hoverCardText(for: counted, now: now).contains("%"))
        XCTAssertTrue(hoverCardText(for: measured, now: now).contains("43% of context · 85k tokens in context"))
    }

    /// The card waits half a second, and a row that showed nothing until then left the
    /// pointer with no sign it was over anything.
    func testAHoveredRowLightsUpImmediatelyAndGoesBackWhenThePointerLeaves() {
        let laidOut = row()
        XCTAssertNil(laidOut.layer?.backgroundColor, "a row at rest carries no wash")

        laidOut.mouseEntered(with: NSEvent())
        let highlighted = laidOut.layer?.backgroundColor
        laidOut.mouseExited(with: NSEvent())

        XCTAssertEqual(highlighted?.alpha ?? 0, WidgetBackground.graphite.hoverColor.alphaComponent, accuracy: 0.01)
        XCTAssertEqual(laidOut.layer?.backgroundColor?.alpha ?? 1, 0, accuracy: 0.001)
    }

    /// The setting says "stop showing the topic". A card that showed it anyway would keep
    /// exactly the promise the rows had just stopped keeping.
    func testTurningTheTopicOffTakesTheNameOffTheCardToo() {
        let session = snapshot()

        let shown = hoverCardText(for: session, now: now, showsSessionTopic: true)
        let hidden = hoverCardText(for: session, now: now, showsSessionTopic: false)

        XCTAssertTrue(shown.contains(longName))
        XCTAssertFalse(hidden.contains(longName))
        XCTAssertTrue(hidden.contains("Claude Code"), "everything else the card knows still stands")
    }

    /// The button is always pressable, so the card is where a person learns how far one
    /// press gets them — and, when the host is gone, that it gets them nowhere.
    func testTheCardSaysHowFarTheFocusButtonReaches() {
        var live = snapshot()
        live.phase = .executing

        XCTAssertTrue(
            hoverCardText(for: live, now: now, locator: .nowhere).contains("No window to bring forward")
        )
        XCTAssertTrue(
            hoverCardText(for: live, now: now, locator: SessionLocator(applicationName: "Ghostty"))
                .contains("↗ brings Ghostty forward")
        )
        XCTAssertTrue(
            hoverCardText(
                for: live,
                now: now,
                locator: SessionLocator(applicationName: "GoLand", projectName: "mcp-hub", tabName: live.title)
            )
            .contains("the mcp-hub window, terminal tab named above")
        )
    }

    /// With the topic switched off there is no line above to point at, so the tab is not
    /// mentioned — the setting says stop showing the name, and this must not say it by the
    /// back door either.
    func testTheTabIsNotPointedAtWhenTheNameIsHidden() {
        let hint = hoverCardText(
            for: snapshot(),
            now: now,
            showsSessionTopic: false,
            locator: SessionLocator(applicationName: "GoLand", projectName: "mcp-hub", tabName: "Fix the widget")
        )

        XCTAssertTrue(hint.contains("the mcp-hub window"))
        XCTAssertFalse(hint.contains("terminal tab"))
        XCTAssertFalse(hint.contains("Fix the widget"))
    }

    /// The card must not open over a button: aiming at a button is aiming at a button, and a
    /// card appearing under the pointer there would be in the way of the click it interrupted.
    func testTheHoverAreaLeavesTheButtonsAlone() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 20)
        let focus = NSRect(x: 0, y: 0, width: 22, height: 19)
        let dismiss = NSRect(x: 278, y: 0, width: 22, height: 19)

        let both = HUDSessionRowView.hoverRect(in: bounds, avoiding: [focus, dismiss])
        XCTAssertEqual(both, NSRect(x: 22, y: 0, width: 256, height: 20))
        XCTAssertFalse(both.intersects(focus))
        XCTAssertFalse(both.intersects(dismiss))

        // A live session has no dismiss button, so the span runs to the row's own edge.
        XCTAssertEqual(
            HUDSessionRowView.hoverRect(in: bounds, avoiding: [focus]),
            NSRect(x: 22, y: 0, width: 278, height: 20)
        )
    }

    /// A row squeezed until its buttons meet has no information left to explain, and a
    /// hover area of negative width would be a rectangle AppKit cannot use.
    func testARowWithNoRoomBetweenItsButtonsOffersNoHoverArea() {
        let bounds = NSRect(x: 0, y: 0, width: 40, height: 20)
        let focus = NSRect(x: 0, y: 0, width: 22, height: 19)
        let dismiss = NSRect(x: 18, y: 0, width: 22, height: 19)

        XCTAssertEqual(HUDSessionRowView.hoverRect(in: bounds, avoiding: [focus, dismiss]), .zero)
    }

    /// Laid out for real: what the row installs has to be the span, not the whole row.
    func testTheInstalledTrackingAreaMatchesTheSpanBetweenTheButtons() throws {
        var closed = snapshot()
        closed.phase = .sessionClosed
        let laidOut = row(snapshot: closed, onRemove: {})
        laidOut.updateTrackingAreas()

        let area = try XCTUnwrap(laidOut.trackingAreas.first { $0.options.contains(.mouseEnteredAndExited) })
        let buttons = laidOut.arrangedSubviews.compactMap { $0 as? RowActionButton }

        XCTAssertEqual(buttons.count, 2)
        XCTAssertGreaterThan(area.rect.width, 0)
        for button in buttons {
            XCTAssertFalse(area.rect.intersects(button.frame), "\(button.rowAction) is inside the hover area")
        }
    }

    /// The card is opened by a tracking area, and a tracking area that only worked in the
    /// key window would report nothing while another application is in front — which is
    /// most of the time for this widget.
    func testARowReportsThePointerArrivingAndLeaving() {
        var reported: [Bool] = []
        let laidOut = HUDSessionRowView(
            snapshot: snapshot(),
            now: now,
            background: .graphite,
            lampScheme: LampScheme(),
            onFocus: {},
            onRemove: nil,
            onHoverChanged: { _, isInside in reported.append(isInside) }
        )
        laidOut.frame = NSRect(origin: .zero, size: laidOut.fittingSize)
        laidOut.updateTrackingAreas()

        XCTAssertEqual(
            laidOut.trackingAreas.filter { $0.options.contains(.activeAlways) }.count,
            1,
            "a hover that only works in the key window is no hover at all here"
        )

        laidOut.mouseEntered(with: NSEvent())
        laidOut.mouseExited(with: NSEvent())

        XCTAssertEqual(reported, [true, false])
    }

    /// Whatever the row says, the way back to the session is pressable.
    ///
    /// It used not to be. The button was greyed from an answer resolved once, when the
    /// session was first associated with an application, and never asked again — so a row
    /// could sit dead for hours with its application plainly running, and the oldest row in
    /// the widget was the likeliest to be the dead one.
    func testTheFocusButtonIsPressableInEveryPhase() throws {
        for phase in SessionPhase.allCases {
            var session = snapshot()
            session.phase = phase
            let button = try XCTUnwrap(row(snapshot: session).arrangedSubviews.first as? RowActionButton)

            XCTAssertEqual(button.rowAction, .focus, "\(phase)")
            XCTAssertTrue(button.isEnabled, "\(phase)")
        }
    }

    /// The columns after the focus button line up down the list, so the button itself may
    /// not change width with the phase — and the dismiss button, which does come and go,
    /// has to stay out of the way at the far end.
    func testTheLeadingButtonIsTheSameWidthInEveryRow() throws {
        var live = snapshot()
        live.phase = .executing
        var closed = snapshot()
        closed.phase = .sessionClosed

        let liveRow = row(snapshot: live, onRemove: nil)
        let closedRow = row(snapshot: closed, onRemove: {})

        let liveButton = try XCTUnwrap(liveRow.arrangedSubviews.first as? RowActionButton)
        let closedButton = try XCTUnwrap(closedRow.arrangedSubviews.first as? RowActionButton)
        XCTAssertEqual(liveButton.rowAction, .focus)
        XCTAssertEqual(placed(liveButton).width, placed(closedButton).width, accuracy: 0.5)
        XCTAssertEqual(placed(liveButton).width, HUDSessionRowView.buttonWidth, accuracy: 0.5)

        XCTAssertNil(
            liveRow.arrangedSubviews.first { ($0 as? RowActionButton)?.rowAction == .dismiss },
            "a live session has nothing to dismiss"
        )
        XCTAssertEqual(
            (closedRow.arrangedSubviews.last as? RowActionButton)?.rowAction,
            .dismiss,
            "the dismiss button belongs at the end of the row, not next to the focus button"
        )
    }

    /// The gap the user saw: a slot held open for a button that was not there.
    func testALiveRowLeavesNoHoleWhereTheDismissButtonWouldBe() throws {
        var live = snapshot()
        live.phase = .executing

        let laidOut = row(snapshot: live, titleDisplay: .hidden, onRemove: nil)
        let button = try XCTUnwrap(laidOut.arrangedSubviews.first as? RowActionButton)
        let timer = try XCTUnwrap(laidOut.arrangedSubviews.dropFirst().first)

        // Measured between alignment rectangles, which is what a stack's spacing separates —
        // the frames themselves reach a point or two further out on each side.
        XCTAssertEqual(
            placed(timer).minX - placed(button).maxX,
            HUDSessionRowView.buttonGap,
            accuracy: 0.5
        )
        XCTAssertLessThan(HUDSessionRowView.buttonGap, HUDSessionRowView.elementSpacing)
    }

    /// What Auto Layout actually placed, as opposed to the frame drawn around it.
    private func placed(_ view: NSView) -> NSRect {
        view.alignmentRect(forFrame: view.frame)
    }

    /// The point of the budget: a row given the width the widget has must fit inside it.
    /// It did not before — the name was capped against room the row never had, and the row
    /// spilled over and took the horizontal scroller with it.
    func testARowBuiltToTheBudgetFitsTheWidthItWasMeasuredFor() {
        let session = snapshot()
        let contentWidth: CGFloat = 320
        let furniture = nameless(session).furnitureWidth
        let display = chooseTitleDisplay(
            availableWidth: contentWidth - furniture,
            fullTitleWidth: labelWidth(of: session.title ?? "", font: WidgetStyle.titleFont),
            minimumTitleWidth: HUDSessionRowView.minimumTitleWidth
        )

        XCTAssertEqual(display, .truncated(toWidth: contentWidth - furniture), "this name is too long to fit")
        XCTAssertLessThanOrEqual(row(snapshot: session, titleDisplay: display).fittingSize.width, contentWidth)
    }

    /// The blink is installed on the lamp's backing layer, and joining a layer-backed
    /// hierarchy can hand a view a fresh one. Set up once in `init`, the animation was lost
    /// on the way into the window, so the lamp only ever appeared to flash when its row was
    /// rebuilt.
    func testTheLampKeepsBlinkingAfterItJoinsAWindow() throws {
        var working = snapshot()
        working.phase = .executing
        let laidOut = row(snapshot: working)
        let lamp = try XCTUnwrap(laidOut.arrangedSubviews.compactMap { $0 as? SessionLampView }.first)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView?.addSubview(laidOut)
        laidOut.layoutSubtreeIfNeeded()

        XCTAssertTrue(lamp.isBlinking, "a working session's lamp has to pulse on its own")
    }

    func testASteadyLampIsNotAnimatedAtAll() throws {
        var done = snapshot()
        done.phase = .completed
        let lamp = try XCTUnwrap(
            row(snapshot: done).arrangedSubviews.compactMap { $0 as? SessionLampView }.first
        )

        XCTAssertFalse(lamp.isBlinking)
    }

    /// The column only stands straight if every value the timer can print is the same width.
    /// A monospaced-*digit* face is not enough for that: it evens out `9` against `0` and
    /// leaves `m` wider than `d`.
    func testEveryTimerValueTakesTheSameWidth() {
        let widths = ["0s", "59s", "9m", "59m", "1h", "23h", "99d"]
            .map { labelWidth(of: $0, font: WidgetStyle.timerFont) }

        XCTAssertEqual(widths.max() ?? 0, HUDSessionRowView.timerWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            (widths.max() ?? 0) - (widths.min() ?? 0),
            labelWidth(of: "9", font: WidgetStyle.timerFont) + 0.5,
            "a shorter value may be one character narrower, never more"
        )
    }

    /// Whatever it prints, the timer occupies the same three characters, so the lamp of one
    /// row sits directly above the lamp of the next.
    func testTheLampStartsAtTheSamePlaceWhateverTheTimerSays() throws {
        var justNow = snapshot()
        justNow.lastObservedAt = now.addingTimeInterval(-4)
        var longAgo = snapshot()
        longAgo.lastObservedAt = now.addingTimeInterval(-40 * 86_400)

        let first = try XCTUnwrap(lamp(in: row(snapshot: justNow)))
        let second = try XCTUnwrap(lamp(in: row(snapshot: longAgo)))

        XCTAssertEqual(placed(first).minX, placed(second).minX, accuracy: 0.5)
    }

    private func lamp(in row: HUDSessionRowView) -> NSView? {
        row.arrangedSubviews.first { $0 is SessionLampView }
    }

    func testTheLampIsDrawnAtItsOwnSizeRatherThanStretched() {
        let laidOut = row(titleDisplay: .fullName)
        let lamp = laidOut.arrangedSubviews.compactMap { $0 as? SessionLampView }.first

        XCTAssertEqual(lamp?.frame.width ?? 0, SessionLampView.diameter, accuracy: 0.5)
        XCTAssertEqual(lamp?.frame.height ?? 0, SessionLampView.diameter, accuracy: 0.5)
    }

    /// The row's only mark about the widget rather than about the session. It appears only
    /// when there is something to say, because a warning that is always there is furniture.
    func testTheRowCarriesAWarningOnlyWhileSomethingIsWrong() throws {
        var faulted = snapshot()
        faulted.monitoringFault = .unexplainedSilence

        XCTAssertNil(HUDSessionRowView.makeFaultMarker(for: snapshot(), background: .graphite))
        let marker = try XCTUnwrap(
            HUDSessionRowView.makeFaultMarker(for: faulted, background: .graphite) as? NSImageView
        )
        XCTAssertNotNil(marker.image, "this system has to actually have the symbol")

        let tinted = { (view: HUDSessionRowView) in
            view.arrangedSubviews
                .compactMap { $0 as? NSImageView }
                .filter { $0.contentTintColor == WidgetBackground.graphite.warningColor }
        }
        XCTAssertEqual(tinted(row(snapshot: faulted)).count, 1, "the row carries it, not just the factory")
        XCTAssertTrue(tinted(row()).isEmpty)
    }

    /// Shape as well as colour, as the visual language requires — half the palette is light,
    /// and a warning tint that works on graphite can vanish on sand.
    func testTheWarningIsTintedForBothHalvesOfThePalette() {
        XCTAssertNotEqual(WidgetBackground.graphite.warningColor, WidgetBackground.sand.warningColor)
    }

    // MARK: - Building a row

    /// A row before it is given a name — the state its furniture width is measured in.
    private func nameless(_ snapshot: SessionSnapshot) -> HUDSessionRowView {
        HUDSessionRowView(
            snapshot: snapshot,
            now: now,
            background: .graphite,
            lampScheme: LampScheme(),
            onFocus: {},
            onRemove: SessionPresence.isDismissible(snapshot, now: now) ? {} : nil
        )
    }

    private func row(
        snapshot: SessionSnapshot? = nil,
        titleDisplay: SessionTitleDisplay = .fullName,
        onRemove: (() -> Void)? = nil
    ) -> HUDSessionRowView {
        let view = HUDSessionRowView(
            snapshot: snapshot ?? self.snapshot(),
            now: now,
            background: .graphite,
            lampScheme: LampScheme(),
            onFocus: {},
            onRemove: onRemove
        )
        view.setTitle((snapshot ?? self.snapshot()).title, display: titleDisplay)
        view.frame = NSRect(x: 0, y: 0, width: view.fittingSize.width, height: view.fittingSize.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    private func titleLabel(in row: HUDSessionRowView) -> NSTextField? {
        row.arrangedSubviews
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == longName }
    }

    private func snapshot() -> SessionSnapshot {
        testSession(
            title: longName,
            phase: .executing,
            clientKind: .cli,
            lastObservedAt: now.addingTimeInterval(-12)
        )
    }
}
