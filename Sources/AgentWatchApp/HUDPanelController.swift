import AgentWatchCore
import AppKit

@MainActor
final class HUDPanelController: NSWindowController, NSWindowDelegate {
    /// Everything the widget is currently showing. Replaced whole, by `render`, and by
    /// nothing else — see `WidgetState`.
    private var state = WidgetState()
    private var freshnessTimer: Timer?
    private var dismissalTimer: Timer?
    /// A single deadline, including while all sessions wait or rest. No idle polling.
    private(set) var nextDismissRefreshAt: Date?
    private let locator: (SessionSnapshot) -> SessionLocator
    private let focus: (SessionSnapshot) -> Void
    private let remove: (SessionSnapshot) -> Void
    private var background: WidgetBackground
    private var lampScheme: LampScheme
    private var backgroundOpacity: CGFloat
    private let frameStore: HUDFrameStore
    private let settings: WidgetSettingsStore
    /// Survives the wholesale rebuild of the content view controller on every refresh,
    /// so a scrolled list does not jump back to the top twice a second.
    private var savedScrollOffset: NSPoint?
    private let container = HUDContentContainer()
    private let hoverCard = SessionHoverCard()
    /// When the card appears, stays and closes. The rule lives beside the card, free of any
    /// view; what is left here is carrying it out.
    private var hover = HoverCardState()
    private var hoverTimer: Timer?
    /// True while a drag on the border is under way. The widget performs that resize itself,
    /// so `inLiveResize` — which only knows about the window server's own drag — is false
    /// throughout, and without this the self-sizing would fight the drag frame by frame.
    private var isUserResizing = false
    /// Where the widget reads the time. One place, so a test can move it: a row gains its `×`
    /// by the clock alone, and only a clock the test holds can stage that crossing.
    var clock: () -> Date = { .now }

    init(
        locator: @escaping (SessionSnapshot) -> SessionLocator,
        focus: @escaping (SessionSnapshot) -> Void,
        remove: @escaping (SessionSnapshot) -> Void,
        background: WidgetBackground,
        lampScheme: LampScheme,
        backgroundOpacity: CGFloat,
        frameStore: HUDFrameStore,
        settings: WidgetSettingsStore
    ) {
        self.locator = locator
        self.focus = focus
        self.remove = remove
        self.background = background
        self.lampScheme = lampScheme
        self.backgroundOpacity = backgroundOpacity
        self.frameStore = frameStore
        self.settings = settings
        // `.resizable` is kept although the widget performs its own resize: it is what macOS
        // derives the window's `AXResizable` trait from, and a window manager that lays out
        // other windows reads that trait. Not measured against a particular one.
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: frameStore.size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.contentView = container
        container.onPointerLeft = { [weak self] in
            guard let self else {
                return
            }
            apply(hover.pointerLeftWidget())
        }
        container.onResizeBegan = { [weak self] in
            self?.isUserResizing = true
        }
        container.onResizeEnded = { [weak self] in
            guard let self, let panel = window as? HUDPanel else {
                return
            }
            isUserResizing = false
            rememberSize(of: panel)
        }
        container.setBody(
            HUDEmptyStateView(
                background: background,
                backgroundOpacity: backgroundOpacity,
                complaint: state.complaint
            )
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = HUDFrameStore.minimumSize
        panel.hidesOnDeactivate = false
        // Without this a panel that never becomes key sees no pointer movement, and the
        // hover card is a reaction to pointer movement.
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hideStandardButtons()
        panel.delegate = self
        applyInteractionLocks(to: panel)
        position(panel)
    }

    /// Used until the widget has been resized once; after that the saved size wins.
    ///
    /// As tall as the empty state it is created with, so a first launch does not visibly
    /// shrink the moment its first session arrives.
    /// How far the widget grows on its own before it starts scrolling instead.
    private static let maximumAutoSizedRowCount = 8

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        window?.orderFrontRegardless()
        if !state.sessions.isEmpty {
            refreshContent()
        }
    }

    func toggle() {
        guard let window else {
            return
        }

        if window.isVisible {
            window.orderOut(nil)
            endHover()
            freshnessTimer?.invalidate()
            freshnessTimer = nil
            cancelDismissalTimer()
        } else {
            show()
        }
    }

    /// The widget's one input: everything it shows, whole, every time.
    func render(_ state: WidgetState) {
        // A sweep that changed nothing still reports the whole set, and rebuilding for it
        // would throw away the row under the pointer for no reason.
        guard state != self.state else {
            return
        }
        self.state = state
        refreshContent()
    }

    func highlight() {
        show()
        (window as? HUDPanel)?.highlight()
    }

    func setBackground(_ background: WidgetBackground) {
        self.background = background
        refreshContent()
    }

    /// The lamps are rebuilt rather than repainted, because a `SessionLampView` reads its
    /// look once at construction — and `refreshContent()` builds the list again anyway.
    func setLampScheme(_ scheme: LampScheme) {
        lampScheme = scheme
        refreshContent()
    }

    func setBackgroundOpacity(_ opacity: CGFloat) {
        backgroundOpacity = opacity
        refreshContent()
    }

    func shutdown() {
        endHover()
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        cancelDismissalTimer()
        close()
    }

    private func refreshContent() {
        guard let panel = window as? HUDPanel else {
            return
        }

        // The body is swapped inside a container that stays put, rather than replacing the
        // window's content view. Two reasons: the cursor overlay has to outlive a refresh,
        // and assigning a content view *controller* would resize the window to the new
        // view's fitting size — which for a scroll view with no intrinsic height is the
        // window minimum, and collapsed the widget on every refresh.
        if state.sessions.isEmpty {
            container.setBody(
                HUDEmptyStateView(
                    background: background,
                    backgroundOpacity: backgroundOpacity,
                    complaint: state.complaint
                )
            )
        } else {
            showRows(in: panel)
        }

        resizeIfSelfSizing(panel)
        panel.updateHighlightOverlay()
        updateFreshnessTimer()
        updateDismissalTimer(now: clock())
        refreshHoverCard()
    }

    /// Hands the list what every row should show, and lets it rebuild only the rows that
    /// differ.
    ///
    /// A list already on screen is kept unless something it cannot change by itself has
    /// moved: the width decides how much of each name fits, and the usage block under the
    /// divider is not made of rows. Either of those is rare — a resize, a new reading of the
    /// account's limits — and rebuilding the list for them costs nothing anybody sees.
    private func showRows(in panel: HUDPanel, now: Date? = nil) {
        let width = panel.contentLayoutRect.width
        // One moment for the models and for the rows built from them: two readings of the
        // clock would let a row's age disagree with the thresholds decided beside it.
        let moment = now ?? clock()
        let models = orderedForDisplay(state.sessions).map { snapshot in
            HUDRowModel(snapshot: snapshot, now: moment, showsSessionTopic: settings.showsSessionTopic)
        }

        if let listView = container.body as? HUDSessionListView,
            listView.canShow(
                usageLimits: state.usageLimits,
                atWidth: width,
                background: background,
                lampScheme: lampScheme,
                backgroundOpacity: backgroundOpacity
            )
        {
            listView.apply(models: models, now: moment)
            return
        }

        container.setBody(
            HUDSessionListView(
                models: models,
                usageLimits: state.usageLimits,
                now: moment,
                availableWidth: width,
                focus: focus,
                remove: remove,
                background: background,
                lampScheme: lampScheme,
                backgroundOpacity: backgroundOpacity,
                restoredScrollOffset: savedScrollOffset,
                onScroll: { [weak self] offset in
                    self?.savedScrollOffset = offset
                },
                onHoverChanged: { [weak self] row, isInside in
                    self?.hoverChanged(row, isInside: isInside)
                }
            )
        )
    }

    /// Every row the widget is showing, in order. The one way a test can see what the list
    /// did with a report rather than what it was told.
    var visibleRows: [HUDSessionRowView] {
        (container.body as? HUDSessionListView)?.rows ?? []
    }

    /// Keyed by session, not by row view: an event rebuilds the list, and a card tied to the
    /// view it was opened from would vanish mid-read on exactly the busy session a reader is
    /// most likely to be inspecting.
    func hoverChanged(_ row: HUDSessionRowView, isInside: Bool) {
        let sessionID = row.snapshot.id
        apply(isInside ? hover.pointerEntered(sessionID: sessionID) : hover.pointerLeft(sessionID: sessionID))
    }

    /// Carries out what `HoverCardState` decided. Everything that needs a window is here and
    /// nothing that needs a decision is.
    private func apply(_ action: HoverCardAction) {
        switch action {
        case .none:
            break
        case let .arm(sessionID):
            armHoverCard(for: sessionID)
        case let .present(sessionID):
            presentHoverCard(for: sessionID)
        case let .reattach(sessionID):
            // The replacement row gets no arrival of its own if the pointer has not moved, so
            // the highlight has to be put back by hand.
            currentRow(for: sessionID)?.setHighlighted(true)
            refreshHoverCardText(now: clock())
        case .dismiss:
            endHover()
        }
    }

    private func armHoverCard(for sessionID: String) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(
            withTimeInterval: SessionHoverCard.appearanceDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.hoverTimer = nil
                self.showHoverCard(for: sessionID)
            }
        }
    }

    /// The countdown for this session has finished. Shows the card if the pointer is still
    /// where it was; a test uses this to arrive at the same place without waiting half a
    /// second for a timer.
    func showHoverCard(for sessionID: String) {
        apply(hover.countdownFinished(for: sessionID))
    }

    private func presentHoverCard(for sessionID: String) {
        guard let row = currentRow(for: sessionID), let frame = row.frameOnScreen else {
            return
        }
        hoverCard.show(text: cardText(for: row.snapshot, now: clock()), below: frame)
    }

    /// What the hover card is showing, or `nil` when none is open. The card is a window of
    /// its own, so this is how a test sees it.
    var visibleHoverCardText: String? {
        hoverCard.isVisible ? hoverCard.text : nil
    }

    func currentRow(for sessionID: String) -> HUDSessionRowView? {
        (container.body as? HUDSessionListView)?.row(for: sessionID)
    }

    private func cardText(for snapshot: SessionSnapshot, now: Date) -> String {
        hoverCardText(
            for: snapshot,
            now: now,
            showsSessionTopic: settings.showsSessionTopic,
            locator: locator(snapshot)
        )
    }

    /// Also called directly when the widget goes away, which is a dismissal no pointer
    /// reports.
    private func endHover() {
        hover = HoverCardState()
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverCard.hide()
    }

    /// Keeps an open card truthful across a rebuild, and closes it when its session leaves.
    private func refreshHoverCard() {
        apply(hover.sessionsChanged(to: state.sessions.lazy.map(\.id)))
    }

    /// The card carries the same age the row's timer does — "Last event 12s ago". Refreshed
    /// only when the list is rebuilt, it stood still above a row whose timer was ticking, so
    /// the two disagreed for as long as the session stayed quiet.
    private func refreshHoverCardText(now: Date) {
        guard
            hoverCard.isVisible,
            let hoveredSessionID = hover.hoveredSessionID,
            let snapshot = state.sessions.first(where: { $0.id == hoveredSessionID })
        else {
            return
        }
        hoverCard.updateText(cardText(for: snapshot, now: now))
    }

    /// Only touches the size while the widget is still sizing itself. Once a size has
    /// been chosen by hand, a new session must not resize the window under the cursor.
    ///
    /// The `inLiveResize` guard is what makes a hand resize possible at all: events arrive
    /// every few seconds, each one refreshes the content, and without the guard this would
    /// snap the height back mid-drag — so the drag could never finish and no size would
    /// ever be saved to stop the self-sizing.
    private func resizeIfSelfSizing(_ panel: HUDPanel) {
        guard frameStore.sizeFollowsSessions, !panel.inLiveResize, !isUserResizing else {
            return
        }

        let topLeftCorner = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        // Asked of the view that does the laying out, rather than re-derived from its
        // constants here. Two copies of one geometry drift the moment either is touched.
        let listHeight = HUDSessionListView.selfSizedHeight(
            sessionCount: min(state.sessions.count, Self.maximumAutoSizedRowCount),
            usageLimits: state.usageLimits,
            background: background
        )
        // Never shorter than the widget's own minimum, which is the height the empty state
        // needs: a one-row list that came out shorter would leave the widget below the size
        // a person is allowed to drag it to.
        let floor = HUDFrameStore.minimumSize.height
        let height = state.sessions.isEmpty ? floor : max(floor, listHeight)
        // Only when it actually changes. Resizing and repositioning a window are requests to
        // the window server, and this runs on every event — asking it to make the window the
        // size it already is, twice a second, is work nobody sees.
        guard abs(panel.frame.height - height) > 0.5 else {
            return
        }
        panel.setContentSize(NSSize(width: panel.frame.width, height: height))
        position(
            panel,
            preferredOrigin: NSPoint(
                x: topLeftCorner.x,
                y: topLeftCorner.y - panel.frame.height
            )
        )
    }

    private func updateFreshnessTimer() {
        guard
            window?.isVisible == true,
            state.sessions.contains(where: { SessionFreshnessEvaluator.tracksFreshness(for: $0.phase) })
        else {
            freshnessTimer?.invalidate()
            freshnessTimer = nil
            return
        }
        guard freshnessTimer == nil else {
            return
        }

        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTimers()
            }
        }
    }

    /// The one-second tick. Takes the moment as a parameter so a test can advance it
    /// instead of waiting for it.
    func refreshTimers(now: Date = .now) {
        if let panel = window as? HUDPanel, !state.sessions.isEmpty {
            showRows(in: panel, now: now)
        }
        refreshHoverCardText(now: now)
        updateDismissalTimer(now: now)
    }

    private func cancelDismissalTimer() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        nextDismissRefreshAt = nil
    }

    private func updateDismissalTimer(now: Date) {
        guard window?.isVisible == true else {
            cancelDismissalTimer()
            return
        }
        let deadline = state.sessions.filter { !SessionPresence.isDismissible($0, now: now) }
            .map { $0.lastObservedAt + SessionFreshnessEvaluator.defaultDisconnectAfter }.min()
        guard deadline != nextDismissRefreshAt else {
            return
        }
        cancelDismissalTimer()
        guard let deadline else {
            return
        }
        nextDismissRefreshAt = deadline
        dismissalTimer = Timer.scheduledTimer(withTimeInterval: max(0, deadline.timeIntervalSince(now)), repeats: false)
        {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelDismissalTimer()
                self.refreshTimers(now: self.clock())
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === window else {
            return
        }
        frameStore.save(panel.frame.origin)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === window else {
            return
        }
        // A drag changes the size on every frame. Persisting and rebuilding the list that
        // often is wasted work, so both wait for the end of the drag — `windowDidEndLiveResize`
        // for the window server's own, `onResizeEnded` for the one the border strip performs.
        // Auto Layout keeps the rows sensible in the meantime. What is left here is a resize
        // the app did not start and the user did not drag — a window manager, typically.
        guard !panel.inLiveResize, !isUserResizing, !frameStore.sizeFollowsSessions else {
            return
        }
        rememberSize(of: panel)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel, panel === window else {
            return
        }
        rememberSize(of: panel)
    }

    private func rememberSize(of panel: NSPanel) {
        frameStore.save(panel.frame.size)
        // The width decides how much of each session name fits, so the rows are rebuilt
        // once the new width is final.
        refreshContent()
    }

    /// Applies a settings change that only the content knows about.
    ///
    /// `render(_:)` returns early when nothing about the state changed, which is
    /// what keeps the row under the pointer alive — so a setting toggled between two events
    /// would otherwise sit unapplied until the next one arrived, and the menu item would
    /// look broken and then fix itself minutes later.
    func refreshSettings() {
        refreshContent()
    }

    /// Reapplies both locks. Style mask and drag behaviour are mutable at runtime, so a
    /// toggle takes effect without rebuilding the window.
    func refreshInteractionLocks() {
        guard let panel = window as? HUDPanel else {
            return
        }
        applyInteractionLocks(to: panel)
    }

    /// Puts the widget back in the middle of the main screen.
    ///
    /// "Main" here is the screen carrying the menu bar — `NSScreen.screens.first`, the same one
    /// a first launch places the widget on. Not `NSScreen.main`, which is the screen of the
    /// active window: this application is an accessory and is never active, so that would
    /// resolve to wherever some other application happens to be, and the same menu item would
    /// send the widget somewhere different each time.
    ///
    /// Works while the position is locked. The lock exists to stop a stray drag, not the app,
    /// and a widget stranded on a display that has since been unplugged would otherwise have
    /// no way home without turning the lock off first.
    ///
    /// The new place is saved, so it survives a restart the way a dragged one does.
    func resetPosition() {
        guard let panel = window else {
            return
        }
        guard let visibleFrame = NSScreen.screens.first?.visibleFrame else {
            panel.center()
            return
        }

        panel.setFrameOrigin(HUDPlacement.centeredOrigin(for: panel.frame.size, in: visibleFrame))
        // Saved from the window rather than from the arithmetic: the window server rounds an
        // origin to whole points, so on an odd-sized widget the two differ by half a point and
        // the store would hold a position the widget never actually had.
        frameStore.save(panel.frame.origin)
    }

    /// Returns the widget to sizing itself from the number of sessions, at the size a fresh
    /// install has.
    func resetSize() {
        frameStore.resetSize()
        guard let panel = window as? HUDPanel else {
            return
        }
        panel.setContentSize(frameStore.size)
        refreshContent()
    }

    private func applyInteractionLocks(to panel: HUDPanel) {
        let isResizable = !settings.locksSize
        // Both drag surfaces, not just the background: the panel is `.titled` with a
        // transparent bar, so the title strip stays draggable unless `isMovable` is cleared
        // as well.
        panel.isMovable = !settings.locksPosition
        panel.isMovableByWindowBackground = !settings.locksPosition
        // Only on a real change, and the buttons are hidden again straight after. AppKit
        // rebuilds the window's frame view for any assignment to the style mask, and the
        // rebuilt frame arrives with a fresh set of standard buttons — visible ones. Hiding
        // them in `init` alone lasted until the first `Lock Size` toggle, after which a
        // widget with no title bar grew traffic lights.
        if isResizable != panel.styleMask.contains(.resizable) {
            if isResizable {
                panel.styleMask.insert(.resizable)
            } else {
                panel.styleMask.remove(.resizable)
            }
            panel.hideStandardButtons()
        }
        // A resize cursor over an edge that cannot be dragged would be a promise the widget
        // does not keep.
        container.isResizable = isResizable
    }

    private func position(_ panel: NSPanel, preferredOrigin: NSPoint? = nil) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let primaryVisibleFrame = visibleFrames.first else {
            panel.center()
            return
        }

        let margin: CGFloat = 16
        let hadSavedOrigin = frameStore.savedOrigin != nil
        panel.setFrameOrigin(
            HUDPlacement.origin(
                savedOrigin: preferredOrigin ?? frameStore.savedOrigin,
                size: panel.frame.size,
                visibleFrames: visibleFrames,
                primaryVisibleFrame: primaryVisibleFrame,
                margin: margin
            )
        )
        // The first placement is the first time there is a real answer to where the widget
        // is: the middle of a screen this code has just been told about. Written down so the
        // settings file describes the widget completely, rather than by an absence that only
        // the source explains.
        if !hadSavedOrigin {
            frameStore.save(panel.frame.origin)
        }
    }
}
