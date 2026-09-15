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
@MainActor
final class WidgetSettingsWindowController: NSWindowController {
    private let backgroundStore: WidgetBackgroundStore
    private let lampSchemes: LampSchemeStore
    private let settings: WidgetSettingsStore

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

    init(
        backgroundStore: WidgetBackgroundStore,
        lampSchemes: LampSchemeStore,
        settings: WidgetSettingsStore
    ) {
        self.backgroundStore = backgroundStore
        self.lampSchemes = lampSchemes
        self.settings = settings

        let window = NSWindow(
            // Replaced by the content's own fitting size below; a window needs some rect to
            // be born with.
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Watch Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let lamp = makeLampGrid()
        let palette = makeBackgroundGrid()
        let opacity = makeOpacityRow()
        let size = makeScaleRow()
        // The rules are as wide as the widest thing they separate, measured from the sections
        // themselves. A constant here decided the window's width instead, and left a strip of
        // empty window to the right of every control.
        let ruleWidth = [lamp, palette, opacity, size].map(\.fittingSize.width).max() ?? 0

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        content.addView(Self.makeSectionTitle("Lamp"), in: .top)
        content.addView(lamp, in: .top)
        content.addView(makeResetButton(), in: .top)
        content.addView(Self.makeRule(width: ruleWidth), in: .top)
        content.addView(Self.makeSectionTitle("Background"), in: .top)
        content.addView(palette, in: .top)
        content.addView(Self.makeRule(width: ruleWidth), in: .top)
        content.addView(Self.makeSectionTitle("Opacity"), in: .top)
        content.addView(opacity, in: .top)
        content.addView(Self.makeRule(width: ruleWidth), in: .top)
        content.addView(Self.makeSectionTitle("Size"), in: .top)
        content.addView(size, in: .top)

        let container = NSView()
        container.addSubview(content)
        content.pinToEdges(of: container)
        window.contentView = container
        // Sized to its content rather than to the number above: the lamp grid's height comes
        // from nine rows of controls whose size is the system's to decide, not this file's.
        window.setContentSize(content.fittingSize)
        showCurrentValues()
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

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let phase = Self.phase(ofTag: sender.tag) else {
            return
        }
        lampSchemes.setColor(sender.color, for: phase)
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
        showSelectedBackground()
        showOpacity()
        showScale()
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
