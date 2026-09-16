import AgentWatchCore
import AppKit

/// The one window where the widget's appearance is set up.
///
/// The lamp is why it exists. Nine phases with a colour and a motion each is eighteen
/// choices, and a menu can offer that only as nine submenus of submenus — where the person
/// cannot see the scheme they are building. A window shows it at once, and every control
/// takes effect immediately: the widget is on screen while the window is open, so a colour
/// that cannot be seen against the chosen background is a mistake that corrects itself in a
/// second rather than one the app has to prevent by narrowing the choice.
///
/// The background and the transparency moved here from the menu for the same reason — they
/// are appearance, and appearance now has one place.
///
/// The shortcut is the one thing here that is not appearance, and it is here because it cannot
/// be anywhere else: recording a combination needs a control that takes a key press, and a menu
/// line cannot be one.
@MainActor
final class WidgetSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let backgroundStore: WidgetBackgroundStore
    private let lampSchemes: LampSchemeStore
    private let settings: WidgetSettingsStore
    private let rowLayouts: RowLayoutStore
    private let shortcuts: WidgetShortcutController
    /// What the last key press was refused for, shown in place of the status until something
    /// else happens. Transient on purpose: it is about the press, not about the setting.
    private var shortcutRefusal: String?

    /// The controls, kept so a change made elsewhere — the reset button, or the store
    /// clamping a value — can be shown without rebuilding the window.
    ///
    /// Reachable from the tests, which operate them the way a person does: set the value,
    /// then send the action. Nothing outside this file changes them.
    private(set) var colorWells: [SessionPhase: NSColorWell] = [:]
    private(set) var motionButtons: [SessionPhase: NSPopUpButton] = [:]
    private(set) var backgroundButtons: [WidgetBackground: NSButton] = [:]
    private(set) var opacitySlider: NSSlider?
    private(set) var opacityLabel: NSTextField?
    private(set) var scaleSlider: NSSlider?
    private(set) var scaleLabel: NSTextField?
    private(set) var shortcutRecorder: ShortcutRecorderButton?
    private(set) var shortcutClearButton: NSButton?
    private(set) var shortcutStatusLabel: NSTextField?
    /// One control per part, by part, so a test operates the row it means rather than the
    /// third checkbox from the top.
    private(set) var partBoxes: [RowPart: NSButton] = [:]
    private(set) var moveUpButtons: [RowPart: NSButton] = [:]
    private(set) var moveDownButtons: [RowPart: NSButton] = [:]
    private(set) var variantButtons: [RowPart: NSPopUpButton] = [:]
    private(set) var flexibleButtons: [RowPart: NSButton] = [:]
    /// The six kinds the counter block can count, by kind. One menu item each.
    private(set) var counterKindItems: [ActivityKind: NSMenuItem] = [:]
    private(set) var dismissColumnBox: NSButton?
    /// The sample: a real row, built the way the widget builds one. Not a drawing of a row —
    /// a drawing would have to be kept in step with the widget by hand, and the first time it
    /// drifted the window would be teaching somebody the wrong thing.
    private(set) var sampleRow: HUDSessionRowView?
    /// The same sample as a session still at work, which is the row with no × in it.
    private(set) var sampleWorkingRow: HUDSessionRowView?
    private let sampleHolder = NSStackView()
    private let partsGrid = NSGridView(numberOfColumns: 6, rows: 0)

    init(
        backgroundStore: WidgetBackgroundStore,
        lampSchemes: LampSchemeStore,
        settings: WidgetSettingsStore,
        rowLayouts: RowLayoutStore,
        shortcuts: WidgetShortcutController
    ) {
        self.backgroundStore = backgroundStore
        self.lampSchemes = lampSchemes
        self.settings = settings
        self.rowLayouts = rowLayouts
        self.shortcuts = shortcuts

        let window = NSWindow(
            // Replaced by the content's own fitting size below; a window needs some rect to
            // be born with.
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            // Resizable since the content outgrew a screen: the row layout's thirteen rows
            // took the window past the height a laptop has to give, and a window with a
            // scroller a person cannot enlarge is worse than one they can.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Watch Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let rowLayout = makeRowLayoutSection()
        let lamp = makeLampGrid()
        let palette = makeBackgroundGrid()
        let opacity = makeOpacityRow()
        let size = makeScaleRow()
        let shortcut = makeShortcutRow()
        // The one section whose controls do not exist until the template is read: the grid is
        // built row by row from the parts. Measured the other way round — filled in after the
        // window was sized, it left the window twenty points narrower than its own controls,
        // and the section lost its left margin while its last column ran past the right edge.
        // Everything else is filled by `showCurrentValues` below, which changes no widths.
        showRowLayout()
        // The rules are as wide as the widest thing they separate, measured from the sections
        // themselves. A constant here decided the window's width instead, and left a strip of
        // empty window to the right of every control.
        let ruleWidth =
            [rowLayout, lamp, palette, opacity, size, shortcut].map(\.fittingSize.width).max() ?? 0

        // Three tabs rather than one column of six sections. The column asked the window for
        // the height of every section at once — measured, 1290 points against the 1079 a
        // laptop leaves — so the window opened as tall as the screen allowed and the rest was
        // reached by scrolling. A tab is shown on its own, and the window is only ever as tall
        // as the tallest of the three.
        //
        // `Size` stands with the row rather than with the background because it is the row it
        // makes larger: the widget has no size of its own beyond the rows in it.
        let rowTab = Self.makeTabContent([
            rowLayout,
            Self.makeRule(width: ruleWidth),
            Self.makeSectionTitle("Size"),
            size,
        ])
        // No title over the lamp grid, and none over the parts: the tab says it already.
        let lampTab = Self.makeTabContent([lamp, makeResetButton()])
        let otherTab = Self.makeTabContent([
            Self.makeSectionTitle("Background"),
            palette,
            Self.makeRule(width: ruleWidth),
            Self.makeSectionTitle("Opacity"),
            opacity,
            Self.makeRule(width: ruleWidth),
            Self.makeSectionTitle(shortcutSectionTitle),
            shortcut,
            makeShortcutStatusLabel(width: ruleWidth),
        ])

        let tabs = NSTabView()
        // Room to lay out in before anything is measured. A tab view still at its birth size
        // lays its tab out at that size, and the window's own birth size — 400 points, a
        // number that only exists because a window has to be born with some rectangle — is
        // narrower than the parts grid's stated columns. Nothing is drawn there, but the
        // layout is still solved there, and an impossible one is printed to the console.
        tabs.setFrameSize(NSSize(width: 1_000, height: 1_000))
        for (label, tab) in [("Row", rowTab), ("Lamp", lampTab), ("Other", otherTab)] {
            let item = NSTabViewItem()
            item.label = label
            item.view = Self.scrolling(tab)
            tabs.addTabViewItem(item)
        }

        // Sized to its content rather than to a number written here: the lamp grid's height
        // comes from nine rows of controls whose size is the system's to decide, not this
        // file's.
        //
        // The right margin is added by hand, the way the tooling window adds its own: a
        // vertical stack aligned to its leading edge pins nothing to the other one, so its
        // fitting width is the left inset plus the widest section, and the section's last
        // column would sit flush against the window's edge.
        let widest = [rowTab, lampTab, otherTab].map(\.fittingSize.width).max() ?? 0
        let tallest = [rowTab, lampTab, otherTab].map(\.fittingSize.height).max() ?? 0
        // What the tab strip and its border take, asked of the tab view rather than guessed:
        // `contentRect` is the room it leaves for the tab that is showing.
        let chrome = NSSize(
            width: tabs.frame.width - tabs.contentRect.width,
            height: tabs.frame.height - tabs.contentRect.height
        )
        // And the scroller's own strip where the system draws one. A tab that outgrows the
        // window scrolls, and with "Always show scroll bars" the strip is taken out of the
        // content rather than laid over it. Measured: 15 points, which is the whole right
        // margin but five.
        let width = widest + rowTab.edgeInsets.right + Self.scrollerStrip + chrome.width
        window.contentMinSize = NSSize(width: width, height: 240)
        window.setContentSize(
            NSSize(
                width: width,
                height: min(tallest + chrome.height, Self.tallestUsefulWindow)
            ))
        // And only now into the window, which is the size its tabs asked for. Put in first,
        // the tabs would be laid out twice: once at the size the window was born with, and
        // once here.
        window.contentView = tabs
        // The window is the only place a failed registration can be seen, so it listens rather
        // than reading the status once at construction: the combination may be taken by
        // something that starts up after this window did.
        shortcuts.onStatusChange = { [weak self] in
            self?.shortcutRefusal = nil
            self?.showShortcut()
        }
        window.delegate = self
        showCurrentValues()
    }

    /// As tall as the screen leaves room for, and no taller — the same rule the tooling
    /// window follows. Past this the sections are reached by scrolling, which is the one
    /// thing a window taller than the screen cannot offer.
    static var tallestUsefulWindow: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * 0.9
    }

    /// One tab's sections, in the column they are read in.
    ///
    /// Flipped, for the reason the widget's own list is: an unflipped document view is
    /// anchored at its bottom-left corner, so a tab with less in it than the window is tall
    /// hung from the bottom edge with the empty half above it.
    private static func makeTabContent(_ sections: [NSView]) -> NSStackView {
        let content = FlippedStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for section in sections {
            content.addView(section, in: .top)
        }
        return content
    }

    /// A tab's content in a scroll view, for the reason the tooling window has one: a tab can
    /// still be taller than a laptop screen leaves room for, and a window is not moved above
    /// the menu bar to show the rest. Where it fits, the scroller is not drawn at all.
    private static func scrolling(_ content: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // And sideways, for the one case the width below gives up on: a tab narrower than
        // its own controls is scrolled to rather than cut off. Hidden while it is not needed.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        // As wide as the window, but not at any cost. Required, this was an impossible demand
        // whenever the window was narrower than the tab's own controls — and the window is
        // born 400 points wide and measures its tabs only afterwards, so it passes through
        // that state every time it opens. AppKit resolved it by breaking a stated column
        // width in the parts grid and saying so in the console.
        //
        // Below required, the same set is satisfiable: the tab keeps the width its controls
        // need, and the scroll view offers the rest sideways. The trailing edge is not pinned
        // separately — with the leading edge pinned it is this same constraint said twice,
        // and at full priority it would have gone on making the demand impossible.
        let fillsTheWindow = content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        fillsTheWindow.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            fillsTheWindow,
        ])
        return scroll
    }

    /// What a scroller takes from the content's width, which is nothing unless the system
    /// draws the old solid strip rather than the overlay that fades in over the content.
    private static var scrollerStrip: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }

    /// Closing the window in the middle of a recording is a change of mind like any other, and
    /// it is the one the recorder cannot notice for itself: measured, AppKit leaves the focus
    /// on the control inside a window it closes. Without this the combination stayed quiet
    /// after the window was gone — still registered, still printed beside the menu line, and
    /// doing nothing until the next visit here.
    func windowWillClose(_ notification: Notification) {
        stopRecordingShortcut()
    }

    /// And leaving for another application, which is neither of the above: the window stays
    /// open with the recorder still focused, and no key press is coming. Recoverable where the
    /// other two are not — the person can come back and press something — but until they do,
    /// the shortcut is registered and silent.
    func windowDidResignKey(_ notification: Notification) {
        stopRecordingShortcut()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var isShowing: Bool {
        window?.isVisible == true
    }

    /// Opens the window, or brings it forward if it is already open.
    ///
    /// Not a toggle, unlike the debug window: a settings window is closed with its own close
    /// button, and a menu line that sometimes closes it instead of showing it would need the
    /// person to know which of the two it is about to do.
    func present() {
        // The values are read again on the way in: the file is one document and something
        // else may have written part of it since — the widget's own frame, or a person
        // editing it by hand and restarting.
        showCurrentValues()
        showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: - The row layout

    /// The sample first, then the controls that change it.
    ///
    /// A person placing a part is asking "what will my row look like", and the answer is a
    /// row — not a list of names they have to assemble in their head. What the sample cannot
    /// answer is the part a session happens to have nothing to put in: it is simply not there,
    /// and no drawing can show an absence. That is what the `appears` column beside each part
    /// is for, and why the sample session has something for every one of them.
    private func makeRowLayoutSection() -> NSView {
        sampleHolder.orientation = .vertical
        sampleHolder.alignment = .leading
        sampleHolder.edgeInsets = NSEdgeInsets(top: 5, left: 4, bottom: 5, right: 4)
        sampleHolder.wantsLayer = true
        sampleHolder.layer?.cornerRadius = WidgetStyle.rowCornerRadius
        sampleHolder.layer?.backgroundColor = backgroundStore.selected.color.cgColor

        partsGrid.rowSpacing = 4
        partsGrid.columnSpacing = 10
        partsGrid.xPlacement = .leading

        let keepColumn = NSButton(
            checkboxWithTitle: "Keep the × column on every row",
            target: self,
            action: #selector(dismissColumnChanged(_:))
        )
        keepColumn.toolTip = """
            A session still at work has no × to press, so without the column what a row ends \
            with sits further right than a finished session's.
            """
        dismissColumnBox = keepColumn

        let reset = NSButton(title: "Use the app's own row", target: self, action: #selector(resetRowLayout))
        reset.bezelStyle = .rounded
        reset.toolTip = "Puts back the row this app draws when nobody has changed it."

        let section = NSStackView(views: [sampleHolder, partsGrid, keepColumn, reset])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        return section
    }

    /// Rebuilds the sample and the grid from the template as it now stands.
    ///
    /// Everything at once rather than the one control that was touched: switching a part off
    /// can move the part that gives way, and moving a part changes which arrows are still
    /// available. Cheap — thirteen rows of controls, rebuilt when a person clicks.
    private func showRowLayout() {
        let layout = rowLayouts.layout
        showSampleRow(layout)

        partBoxes.removeAll()
        moveUpButtons.removeAll()
        moveDownButtons.removeAll()
        variantButtons.removeAll()
        flexibleButtons.removeAll()
        counterKindItems.removeAll()
        // The views go with the row. `removeRow(at:)` takes the row out of the grid and
        // leaves its controls in the window — the grid stops laying them out, and they go on
        // drawing where they last stood. Found in the running window with three copies of the
        // whole section stacked up: one from the window being built, one more from every
        // visit and every click. Identical copies only read as thick text; once a part had
        // been moved, the old order and the new one were drawn one over the other.
        while partsGrid.numberOfRows > 0 {
            let row = partsGrid.row(at: 0)
            for index in 0..<row.numberOfCells {
                row.cell(at: index).contentView?.removeFromSuperview()
            }
            partsGrid.removeRow(at: 0)
        }

        // A caption row, because two of the columns cannot say what they are on their own: a
        // bare radio button means nothing, and `only in a git repo` beside a part could be
        // read as a warning rather than as an answer to "when does this show up".
        partsGrid.addRow(with: Self.makeColumnCaptions())

        for (index, part) in Self.orderedParts(of: layout).enumerated() {
            // The row's own parts come first, and the ones left out after them, so an arrow
            // is offered only where there is somewhere within the group to go.
            let shownCount = layout.parts.count
            let group = layout.shows(part) ? 0..<shownCount : shownCount..<RowPart.allCases.count
            partsGrid.addRow(with: makePartRow(part, at: index, within: group, layout: layout))
        }
        // The columns that hold text are stated, for the reason the lamp grid states its own:
        // left to itself the grid gave the slack to the widest cell and squeezed the rest —
        // drawn, the `appears` column had been cut to two characters. The arrows and the
        // radio are left to their own size, which is the size of a button.
        partsGrid.column(at: 0).width = 104
        partsGrid.column(at: 3).width = 118
        partsGrid.column(at: 4).width = 168
    }

    /// What each column is, said once at the top rather than in every row.
    private static func makeColumnCaptions() -> [NSView] {
        ["", "", "", "appears", "shows", "gives way"].map { caption in
            let label = NSTextField(labelWithString: caption)
            label.font = WidgetStyle.standard.secondaryFont
            label.textColor = .tertiaryLabelColor
            return label
        }
    }

    /// Every part, in the order the row draws them, with the ones left out after them. A part
    /// switched off has no place in the row, and the end of the list is the honest place for
    /// "not in the row at all".
    private static func orderedParts(of layout: RowLayout) -> [RowPart] {
        layout.parts + RowPart.allCases.filter { !layout.parts.contains($0) }
    }

    private func makePartRow(
        _ part: RowPart,
        at index: Int,
        within group: Range<Int>,
        layout: RowLayout
    ) -> [NSView] {
        let isShown = layout.shows(part)

        // The gap has no checkbox: a row without one has no right edge. It keeps its arrows.
        let name: NSView
        if part == .gap {
            let label = NSTextField(labelWithString: "↔  \(part.settingsName)")
            label.font = WidgetStyle.standard.titleFont
            label.textColor = .secondaryLabelColor
            name = label
        } else {
            let box = NSButton(
                checkboxWithTitle: part.settingsName,
                target: self,
                action: #selector(partShownChanged(_:))
            )
            box.state = isShown ? .on : .off
            box.tag = Self.tag(of: part)
            partBoxes[part] = box
            name = box
        }
        name.toolTip = part.appearsWhen

        let when = NSTextField(labelWithString: part.appearsWhenBriefly)
        when.font = WidgetStyle.standard.secondaryFont
        when.textColor = .tertiaryLabelColor
        when.lineBreakMode = .byTruncatingTail
        when.toolTip = part.appearsWhen
        when.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The arrows beside the part they move, not at the far end of the row: drawn with the
        // choices between them, a part and its own arrows sat two hundred points apart and the
        // eye had to walk back along an empty line to pair them up.
        return [name] + makeArrowCells(part, at: index, within: group)
            + [when, makeChoiceCell(part, isShown: isShown, layout: layout)]
            + [makeFlexibleCell(part, isShown: isShown, layout: layout)]
    }

    /// What this part shows, for the parts that can be asked for more than one thing.
    private func makeChoiceCell(_ part: RowPart, isShown: Bool, layout: RowLayout) -> NSView {
        if part == .counters {
            return makeCounterKindsButton(isShown: isShown, layout: layout)
        }
        guard !part.variantTitles.isEmpty else {
            return NSView()
        }
        let choice = NSPopUpButton()
        choice.addItems(withTitles: part.variantTitles)
        choice.selectItem(at: Self.variantIndex(of: part, in: layout))
        choice.target = self
        choice.action = #selector(variantChanged(_:))
        choice.tag = Self.tag(of: part)
        choice.isEnabled = isShown
        variantButtons[part] = choice
        return choice
    }

    /// The kinds of work the counter block counts, as one pull-down with a mark beside each.
    ///
    /// One control rather than six rows of their own: the counters are one part of the row —
    /// they are placed together and moved together — and six near-identical rows in the grid
    /// would bury the twelve parts among them. A pull-down also has room for the words
    /// (`background tasks`, not an icon), which is what tells the six kinds apart at all.
    private func makeCounterKindsButton(isShown: Bool, layout: RowLayout) -> NSView {
        let button = NSPopUpButton()
        // A pull-down rather than a list of alternatives: these are six independent marks,
        // not one choice out of six, and a pull-down's first item is its title.
        button.pullsDown = true
        button.isEnabled = isShown
        button.toolTip = """
            Which kinds of work the block counts. Switch them all off and it counts them all \
            again: a block drawing nothing looks exactly like a session with no work.
            """

        let menu = NSMenu()
        menu.addItem(withTitle: Self.counterKindsTitle(layout.counterKinds), action: nil, keyEquivalent: "")
        for kind in ActivityKind.allCases {
            let item = NSMenuItem(
                title: kind.settingsName,
                action: #selector(counterKindChanged(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.state = layout.counterKinds.contains(kind) ? .on : .off
            item.representedObject = kind.rawValue
            menu.addItem(item)
            counterKindItems[kind] = item
        }
        button.menu = menu
        return button
    }

    /// The pull-down's own line, which is all a closed menu shows.
    private static func counterKindsTitle(_ kinds: Set<ActivityKind>) -> String {
        kinds.count == ActivityKind.allCases.count
            ? "All kinds"
            : "\(kinds.count) of \(ActivityKind.allCases.count) kinds"
    }

    /// Whether this part is the one that narrows, for every part that has anything to give up.
    ///
    /// Its own column rather than shared with the choice above: a part can need both, and the
    /// name — which is what gives way until somebody says otherwise — is exactly such a part.
    /// Sharing the cell left the name with no radio at all, so the row could be taken off the
    /// name and never put back except by resetting the whole template.
    private func makeFlexibleCell(_ part: RowPart, isShown: Bool, layout: RowLayout) -> NSView {
        guard part.canGiveWay else {
            return NSView()
        }
        // The column's caption says what it is, so the button itself says nothing: thirteen
        // rows repeating "gives way" is a word to read thirteen times and a wider window.
        let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(flexibleChanged(_:)))
        radio.state = layout.flexible == part ? .on : .off
        radio.tag = Self.tag(of: part)
        radio.isEnabled = isShown
        radio.setAccessibilityTitle("\(part.settingsName) gives way")
        radio.toolTip = """
            The one part that narrows when the widget does. Every other part keeps its width, \
            so a count or a timer never becomes something ambiguous.
            """
        flexibleButtons[part] = radio
        return radio
    }

    /// - Parameter group: the places this part may move between — the row's own parts, or the
    ///   ones left out of it. A part cannot cross from one into the other by an arrow: that is
    ///   what its checkbox does, and an arrow that silently did nothing was the alternative.
    private func makeArrowCells(_ part: RowPart, at index: Int, within group: Range<Int>) -> [NSView] {
        let up = NSButton(title: "↑", target: self, action: #selector(movePartEarlier(_:)))
        up.bezelStyle = .rounded
        up.tag = Self.tag(of: part)
        up.isEnabled = index > group.lowerBound
        up.toolTip = "Move this part one place earlier in the row"
        moveUpButtons[part] = up

        let down = NSButton(title: "↓", target: self, action: #selector(movePartLater(_:)))
        down.bezelStyle = .rounded
        down.tag = Self.tag(of: part)
        down.isEnabled = index < group.upperBound - 1
        down.toolTip = "Move this part one place later in the row"
        moveDownButtons[part] = down

        return [up, down]
    }

    /// The sample, rebuilt: a row is given its parts once, at construction, so showing a new
    /// template means a new row.
    /// Two rows, because one of the settings here is about the difference between them.
    ///
    /// A session still at work has no `×` to press, so `Keep the × column` shows up only as a
    /// comparison: with it, the two rows end in the same place; without it, the working row's
    /// last part sits a button further right. One sample row could not show that at all — the
    /// checkbox redrew an identical row and looked broken.
    private func showSampleRow(_ layout: RowLayout) {
        sampleWorkingRow.map(sampleHolder.removeView)
        sampleRow.map(sampleHolder.removeView)
        let background = backgroundStore.selected
        sampleHolder.layer?.backgroundColor = background.color.cgColor

        let working = makeSampleRow(
            Self.sampleSession,
            // Long enough that the row is plainly at work rather than a session that has just
            // spoken, and short of every threshold that would change the lamp.
            dismissal: .notOffered(until: Self.sampleSession.lastObservedAt.addingTimeInterval(1_800)),
            layout: layout,
            background: background
        )
        // The finished one carries a × so that the column can be seen and placed. It presses
        // nothing: there is no row to remove, and a button here that did something would be
        // the one control in this window that is not about the drawing.
        let finished = makeSampleRow(
            Self.finishedSampleSession,
            dismissal: .now,
            layout: layout,
            background: background
        )
        sampleHolder.addView(working, in: .top)
        sampleHolder.addView(finished, in: .top)
        sampleWorkingRow = working
        sampleRow = finished
    }

    private func makeSampleRow(
        _ snapshot: SessionSnapshot,
        dismissal: RowDismissal,
        layout: RowLayout,
        background: WidgetBackground
    ) -> HUDSessionRowView {
        let row = HUDSessionRowView(
            snapshot: snapshot,
            now: snapshot.lastObservedAt.addingTimeInterval(4),
            background: background,
            lampScheme: lampSchemes.scheme,
            layout: layout,
            onFocus: {},
            dismissal: dismissal,
            onRemove: {}
        )
        row.setFlexibleText(
            layout.flexible.flatMap { rowPartText($0, for: snapshot, layout: layout) },
            display: .fullName
        )
        return row
    }

    /// One session that has something for every part, including the ones a real session
    /// almost never fills. A sample built from an ordinary session would silently leave the
    /// fault marker and the thread out, and then they could not be placed at all.
    private static let sampleSession = makeSampleSession(id: "codex:sample", phase: .executing)

    /// The same session, finished. The same parts on purpose — the pair is there so two rows
    /// can be compared with each other, and rows made of different parts compare nothing.
    private static let finishedSampleSession = makeSampleSession(
        id: "codex:sample-finished", phase: .completed)

    private static func makeSampleSession(id: String, phase: SessionPhase) -> SessionSnapshot {
        var sample = SessionSnapshot(
            id: id,
            source: .codex,
            arrivalIndex: 0,
            title: "Port the probe to the new API",
            projectName: "agent-watch",
            gitBranch: "row-format",
            mode: .unknown,
            phase: phase,
            activities: [
                SessionActivity(id: "a", kind: .shell, startedAt: .distantPast),
                SessionActivity(id: "b", kind: .tool, startedAt: .distantPast),
            ],
            lastObservedAt: .distantPast,
            clientKind: .cli
        )
        sample.modelName = "gpt-5-codex"
        sample.reasoningEffort = "high"
        sample.threadKind = .subagent
        sample.threadNickname = "Darwin"
        sample.monitoringFault = .transcriptNotFound
        sample.contextTelemetry = .init(totalInputTokens: 212_000, usedPercentage: 63)
        return sample
    }

    @objc private func partShownChanged(_ sender: NSButton) {
        guard let part = Self.part(ofTag: sender.tag) else {
            return
        }
        var parts = rowLayouts.layout.parts
        if sender.state == .on {
            // In front of the gap: a part switched on joins what the row reads first, which
            // is where a person looking for it will look.
            parts.insert(part, at: parts.firstIndex(of: .gap) ?? parts.count)
        } else {
            parts.removeAll { $0 == part }
        }
        store(parts: parts)
    }

    @objc private func movePartEarlier(_ sender: NSButton) {
        movePart(ofTag: sender.tag, by: -1)
    }

    @objc private func movePartLater(_ sender: NSButton) {
        movePart(ofTag: sender.tag, by: 1)
    }

    /// Moves within the whole list — the parts in the row followed by the parts left out — so
    /// that the last arrow down does not disappear into a part that is not drawn.
    private func movePart(ofTag tag: Int, by step: Int) {
        guard let part = Self.part(ofTag: tag) else {
            return
        }
        let layout = rowLayouts.layout
        // Only the parts in the row have an order to change. A part left out is placed by its
        // checkbox, which puts it in front of the gap.
        guard layout.shows(part) else {
            return
        }
        var parts = layout.parts
        guard
            let from = parts.firstIndex(of: part),
            parts.indices.contains(from + step)
        else {
            return
        }
        parts.swapAt(from, from + step)
        store(parts: parts)
    }

    @objc private func variantChanged(_ sender: NSPopUpButton) {
        guard let part = Self.part(ofTag: sender.tag) else {
            return
        }
        // A pop-up with nothing selected answers -1, and a list read at -1 is a crash rather
        // than a setting. Nothing here can produce one — every list is built with a selection
        // — so this is the guard, not a repair: an unreadable answer changes nothing.
        let contextStyles: [RowLayout.ContextStyle] = [.percent, .tokens, .both]
        let chosen = sender.indexOfSelectedItem
        guard chosen >= 0 else {
            return
        }
        rowLayouts.setLayout(
            rowLayouts.layout.changing(
                nameStyle: part == .name ? (chosen == 1 ? .title : .fallback) : nil,
                modelStyle: part == .model ? (chosen == 1 ? .effort : .plain) : nil,
                contextStyle: part == .context ? contextStyles[min(chosen, contextStyles.count - 1)] : nil
            )
        )
        showRowLayout()
    }

    /// The mark beside the item is what was stored, and AppKit does not flip it for a press —
    /// so the press means "the other way round from what you see".
    @objc private func counterKindChanged(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let kind = ActivityKind(rawValue: raw)
        else {
            return
        }
        var kinds = rowLayouts.layout.counterKinds
        if sender.state == .on {
            kinds.remove(kind)
        } else {
            kinds.insert(kind)
        }
        rowLayouts.setLayout(rowLayouts.layout.changing(counterKinds: kinds))
        showRowLayout()
    }

    @objc private func flexibleChanged(_ sender: NSButton) {
        guard let part = Self.part(ofTag: sender.tag) else {
            return
        }
        store(parts: rowLayouts.layout.parts, flexible: part)
    }

    @objc private func dismissColumnChanged(_ sender: NSButton) {
        rowLayouts.setLayout(rowLayouts.layout.changing(reservesDismissColumn: sender.state == .on))
        showRowLayout()
    }

    @objc func resetRowLayout() {
        rowLayouts.setLayout(.standard)
        showRowLayout()
    }

    /// Writes a new order, keeping everything the order does not decide.
    private func store(parts: [RowPart], flexible: RowPart? = nil) {
        rowLayouts.setLayout(rowLayouts.layout.changing(parts: parts, flexible: flexible))
        showRowLayout()
    }

    private static func variantIndex(of part: RowPart, in layout: RowLayout) -> Int {
        switch part {
        case .name: layout.nameStyle == .title ? 1 : 0
        case .model: layout.modelStyle == .effort ? 1 : 0
        case .context:
            switch layout.contextStyle {
            case .percent: 0
            case .tokens: 1
            case .both: 2
            }
        default: 0
        }
    }

    private static func tag(of part: RowPart) -> Int {
        (RowPart.allCases.firstIndex(of: part) ?? 0) + 1
    }

    private static func part(ofTag tag: Int) -> RowPart? {
        RowPart.allCases.indices.contains(tag - 1) ? RowPart.allCases[tag - 1] : nil
    }

    // MARK: - The lamp

    private func makeLampGrid() -> NSView {
        // The phase first, then what to do about it: a settings row reads as a sentence, and
        // a colour well with no name in front of it says nothing.
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.xPlacement = .leading

        for phase in SessionPhase.allCases {
            let well = NSColorWell(style: .default)
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.tag = Self.tag(of: phase)
            // The well's own fitting size, measured rather than chosen. Given anything
            // smaller it draws its bezel outside the frame — at 24 points high a pale edge
            // showed along the left and bottom of every colour — and given a grid column with
            // slack in it, the whole first column stretched and left 127 points of nothing
            // between a colour and the motion beside it.
            well.pinSize(to: Self.colorWellSize)
            colorWells[phase] = well

            let motion = NSPopUpButton()
            motion.target = self
            motion.action = #selector(motionChanged(_:))
            motion.tag = Self.tag(of: phase)
            for option in SessionLampAppearance.Motion.allCases {
                motion.addItem(withTitle: option.title)
                motion.lastItem?.representedObject = option.rawValue
            }
            motionButtons[phase] = motion

            let name = NSTextField(labelWithString: phase.settingsName)
            name.font = WidgetStyle.standard.titleFont

            // On all three, because a person hovers whichever part of the row they are about
            // to change, and the explanation is what tells them whether it is the right row.
            for view in [well, motion, name] as [NSView] {
                view.toolTip = phase.explanation
            }
            grid.addRow(with: [name, well, motion])
        }
        // Stated rather than left to the grid. Given a width to fill — and the separator
        // below sets one — `NSGridView` spreads the slack across its columns, which put 127
        // points of nothing between a colour and the motion beside it.
        grid.column(at: 0).width = Self.phaseColumnWidth
        grid.column(at: 1).width = Self.colorWellSize.width
        grid.column(at: 2).width = 108
        return grid
    }

    /// Wide enough for the longest phase name at the row font, measured once rather than
    /// guessed, so a longer name in a later version widens the column instead of clipping.
    private static let phaseColumnWidth: CGFloat = {
        let longest =
            SessionPhase.allCases
            .map { $0.settingsName.size(withAttributes: [.font: WidgetStyle.standard.titleFont]).width }
            .max() ?? 0
        return longest.rounded(.up) + 4
    }()

    private func makeResetButton() -> NSView {
        let button = NSButton(
            title: "Use the app's own lamp",
            target: self,
            action: #selector(resetLamp)
        )
        button.bezelStyle = .rounded
        button.toolTip = "Forgets every colour and motion chosen here, phase by phase."
        return button
    }

    private func makeShortcutRow() -> NSView {
        let recorder = ShortcutRecorderButton(
            title: shortcutEmptyButton,
            target: self,
            action: #selector(startRecordingShortcut)
        )
        recorder.bezelStyle = .rounded
        // A fixed width so the row does not jump about between "Click to record" and "⌥⌘W",
        // which are nowhere near the same length.
        recorder.widthAnchor.constraint(equalToConstant: 168).isActive = true
        recorder.toolTip = shortcutAcceptedKeys
        recorder.onRecording = { [weak self] recording in
            self?.shortcutRecorded(recording)
        }
        shortcutRecorder = recorder

        let clear = NSButton(title: shortcutClearTitle, target: self, action: #selector(clearShortcut))
        clear.bezelStyle = .rounded
        self.shortcutClearButton = clear

        let row = NSStackView(views: [recorder, clear])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeShortcutStatusLabel(width: CGFloat) -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = WidgetStyle.standard.secondaryFont
        label.textColor = .secondaryLabelColor
        // Wrapping rather than truncating, and bounded by the width the sections already agreed
        // on: the longest of these sentences names a combination and says what to do about it,
        // and a person who cannot read the end of it learns nothing.
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        // Room for the longest sentence, measured rather than guessed at, and fixed so that the
        // window does not resize itself under the pointer every time the status changes.
        let tallest = shortcutEveryStatusLine().reduce(CGFloat(0)) { tallest, line in
            label.stringValue = line
            let needed = label.sizeThatFits(
                NSSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            return max(tallest, needed)
        }
        label.stringValue = ""
        label.heightAnchor.constraint(equalToConstant: tallest).isActive = true
        shortcutStatusLabel = label
        return label
    }

    @objc private func startRecordingShortcut() {
        guard let recorder = shortcutRecorder else {
            return
        }
        shortcutRefusal = nil
        recorder.startRecording()
        // The old combination is still registered while the new one is being chosen, and
        // pressing it here would hide the widget out from under the person doing the choosing.
        shortcuts.isMuted = true
        showShortcut()
    }

    /// Ends a recording nobody is going to finish, and hands the combination its voice back.
    ///
    /// Through the same path a `⎋` takes, so there is one place that decides what the end of a
    /// recording does.
    private func stopRecordingShortcut() {
        guard let recorder = shortcutRecorder, recorder.isRecording else {
            return
        }
        recorder.stopRecording()
        shortcutRecorded(.cancelled)
    }

    @objc private func clearShortcut() {
        shortcutRefusal = nil
        shortcutRecorder?.stopRecording()
        shortcuts.isMuted = false
        settings.setToggleShortcut(nil)
        showShortcut()
    }

    private func shortcutRecorded(_ recording: ShortcutRecording) {
        switch recording {
        case let .recorded(shortcut):
            shortcutRefusal = nil
            settings.setToggleShortcut(shortcut)
        case .cleared:
            shortcutRefusal = nil
            settings.setToggleShortcut(nil)
        case .cancelled:
            shortcutRefusal = nil
        case .refused:
            shortcutRefusal = shortcutAcceptedKeys
        }
        // A refused press leaves the recorder waiting for another, and the old combination has
        // to stay quiet for exactly as long as that lasts.
        shortcuts.isMuted = shortcutRecorder?.isRecording ?? false
        showShortcut()
    }

    private func showShortcut() {
        guard let recorder = shortcutRecorder else {
            return
        }
        recorder.title =
            recorder.isRecording
            ? shortcutRecordingButton
            : (settings.toggleShortcut?.displayed ?? shortcutEmptyButton)
        shortcutStatusLabel?.stringValue = shortcutRefusal ?? shortcutStatusLine(shortcuts.status)
        shortcutClearButton?.isEnabled = settings.toggleShortcut != nil
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let phase = Self.phase(ofTag: sender.tag) else {
            return
        }
        lampSchemes.setColor(sender.color, for: phase)
        // The sample only, not the whole section: a colour well reports every shade the
        // pointer passes over, and rebuilding thirteen rows of controls on each of those is
        // work nobody asked for — none of them says anything about a colour.
        showSampleRow(rowLayouts.layout)
    }

    @objc private func motionChanged(_ sender: NSPopUpButton) {
        guard
            let phase = Self.phase(ofTag: sender.tag),
            let rawValue = sender.selectedItem?.representedObject as? String,
            let motion = SessionLampAppearance.Motion(rawValue: rawValue)
        else {
            return
        }
        lampSchemes.setMotion(motion, for: phase)
        showSampleRow(rowLayouts.layout)
    }

    @objc func resetLamp() {
        lampSchemes.reset()
        showCurrentValues()
    }

    // MARK: - The background

    private func makeBackgroundGrid() -> NSView {
        let grid = NSGridView(numberOfColumns: 1 + WidgetBackground.dark.count, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        grid.xPlacement = .leading
        addBackgroundRow(WidgetBackground.dark, titled: "Dark", to: grid)
        addBackgroundRow(WidgetBackground.light, titled: "Light", to: grid)
        // Every column stated, for the reason the lamp grid states its own: the slack was
        // going into the last column and left one swatch alone against the far edge.
        grid.column(at: 0).width = 46
        for index in 1..<grid.numberOfColumns {
            grid.column(at: index).width = Self.swatchSize.width + 6
        }
        return grid
    }

    private func addBackgroundRow(_ backgrounds: [WidgetBackground], titled title: String, to grid: NSGridView) {
        let label = NSTextField(labelWithString: title)
        label.font = WidgetStyle.standard.secondaryFont
        label.textColor = .secondaryLabelColor

        var views: [NSView] = [label]
        for background in backgrounds {
            let button = NSButton(title: "", target: self, action: #selector(backgroundChosen(_:)))
            button.setButtonType(.toggle)
            button.bezelStyle = .shadowlessSquare
            button.image = Self.swatch(for: background, selected: false)
            button.imagePosition = .imageOnly
            button.toolTip = background.title
            button.identifier = NSUserInterfaceItemIdentifier(background.rawValue)
            button.pinSize(to: Self.swatchSize)
            backgroundButtons[background] = button
            views.append(button)
        }
        // A short row leaves its trailing cells empty rather than stretching: the light
        // backgrounds have to line up under the dark ones.
        grid.addRow(with: views)
    }

    @objc private func backgroundChosen(_ sender: NSButton) {
        guard
            let rawValue = sender.identifier?.rawValue,
            let background = WidgetBackground(rawValue: rawValue)
        else {
            return
        }
        backgroundStore.select(background)
        showSelectedBackground()
        // The sample is a real row, drawn on the widget's background and with its lamp, and a
        // row takes both at construction. So every control that changes either redraws it.
        showSampleRow(rowLayouts.layout)
    }

    // MARK: - The transparency

    private func makeOpacityRow() -> NSView {
        let slider = NSSlider(
            value: Double(backgroundStore.opacity),
            minValue: Double(WidgetBackgroundStore.minimumOpacity),
            maxValue: 1,
            target: self,
            action: #selector(opacityChanged(_:))
        )
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        opacitySlider = slider

        let readout = NSTextField(labelWithString: "")
        readout.font = WidgetStyle.standard.secondaryFont
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 44).isActive = true
        opacityLabel = readout

        let row = NSStackView(views: [slider, readout])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        backgroundStore.selectOpacity(CGFloat(sender.doubleValue))
        showOpacity()
    }

    // MARK: - The size

    /// How large the widget draws everything it holds.
    ///
    /// A slider that snaps to its tick marks rather than a menu of percentages. The widget is
    /// on screen while this window is open and every step redraws it, so the control is the
    /// preview: a person drags until the rows look right instead of choosing a number and
    /// checking afterwards. Snapping is what keeps that honest — the steps are far enough
    /// apart that each one is a visible change, where a free slider offers hundreds of
    /// positions that mostly look identical.
    private func makeScaleRow() -> NSView {
        let scales = WidgetSettingsStore.offeredScales
        let slider = NSSlider(
            value: Double(settings.scale),
            minValue: Double(WidgetSettingsStore.minimumScale),
            maxValue: Double(WidgetSettingsStore.maximumScale),
            target: self,
            action: #selector(scaleChanged(_:))
        )
        slider.numberOfTickMarks = scales.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 260).isActive = true
        scaleSlider = slider

        let readout = NSTextField(labelWithString: "")
        readout.font = WidgetStyle.standard.secondaryFont
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: 44).isActive = true
        scaleLabel = readout

        let row = NSStackView(views: [slider, readout])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func scaleChanged(_ sender: NSSlider) {
        settings.setScale(CGFloat(sender.doubleValue))
        showScale()
    }

    // MARK: - Showing what is stored

    private func showCurrentValues() {
        let scheme = lampSchemes.scheme
        for phase in SessionPhase.allCases {
            let look = SessionLamp.appearance(for: Self.exampleSession(in: phase), scheme: scheme)
            colorWells[phase]?.color = look.color
            motionButtons[phase]?.selectItem(at: Self.index(of: look.motion))
        }
        showRowLayout()
        showSelectedBackground()
        showOpacity()
        showScale()
        showShortcut()
    }

    private func showSelectedBackground() {
        let selected = backgroundStore.selected
        for (background, button) in backgroundButtons {
            let isSelected = background == selected
            button.state = isSelected ? .on : .off
            button.image = Self.swatch(for: background, selected: isSelected)
        }
    }

    private func showOpacity() {
        let opacity = backgroundStore.opacity
        opacitySlider?.doubleValue = Double(opacity)
        opacityLabel?.stringValue = "\(Int((opacity * 100).rounded()))%"
    }

    private func showScale() {
        let scale = settings.scale
        scaleSlider?.doubleValue = Double(scale)
        scaleLabel?.stringValue = "\(Int((scale * 100).rounded()))%"
    }

    /// A phase needs a snapshot to become a lamp, and the window has no sessions. Only the
    /// phase is read for a colour and a motion, so anything else on it is filler.
    private static func exampleSession(in phase: SessionPhase) -> SessionSnapshot {
        SessionSnapshot(
            id: "settings:\(phase.rawValue)",
            source: .claude,
            arrivalIndex: 0,
            phase: phase,
            lastObservedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private static func makeRule(width: CGFloat) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return line
    }

    static let swatchSize = NSSize(width: 30, height: 24)
    /// `NSColorWell(style: .minimal).fittingSize` on macOS 14, read from the control itself.
    private static let colorWellSize = NSSize(width: 44, height: 28)

    /// The palette entry, with its own selection ring.
    ///
    /// Drawn here rather than left to the button's `state`, because a toggle button's bezel
    /// against a dark window is all but invisible — and which background is chosen is the one
    /// question this row exists to answer.
    private static func swatch(for background: WidgetBackground, selected: Bool) -> NSImage {
        let image = NSImage(size: swatchSize)
        image.lockFocus()
        let inset: CGFloat = selected ? 3 : 1.5
        let body = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: swatchSize).insetBy(dx: inset, dy: inset),
            xRadius: 3,
            yRadius: 3
        )
        background.color.setFill()
        body.fill()
        NSColor.separatorColor.setStroke()
        body.lineWidth = 1
        body.stroke()
        if selected {
            let ring = NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: swatchSize).insetBy(dx: 1, dy: 1),
                xRadius: 5,
                yRadius: 5
            )
            NSColor.controlAccentColor.setStroke()
            ring.lineWidth = 2
            ring.stroke()
        }
        image.unlockFocus()
        return image
    }

    /// The phase a control belongs to, carried in the control's own `tag`.
    ///
    /// `SessionPhase.allCases` is the order the tags follow, so a phase added to the model
    /// joins the window without a second list to keep in step.
    private static func tag(of phase: SessionPhase) -> Int {
        SessionPhase.allCases.firstIndex(of: phase) ?? 0
    }

    private static func phase(ofTag tag: Int) -> SessionPhase? {
        SessionPhase.allCases.indices.contains(tag) ? SessionPhase.allCases[tag] : nil
    }

    private static func index(of motion: SessionLampAppearance.Motion) -> Int {
        SessionLampAppearance.Motion.allCases.firstIndex(of: motion) ?? 0
    }
}
