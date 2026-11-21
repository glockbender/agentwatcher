import AppKit

@MainActor
final class FullScreenDot: NSObject {
    private var panels: [WaitingBeaconPanel] = []
    private let openWaiting: () -> Void
    private let openSettings: () -> Void
    private var waitingCount = 0
    private var isEnabled = false
    private var scope = WaitingBeaconScope.fullScreenOnly

    init(openWaiting: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.openWaiting = openWaiting
        self.openSettings = openSettings
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(self, selector: #selector(spaceChanged(_:)), name: name, object: nil)
        }
        workspace.addObserver(
            self, selector: #selector(displayChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show(waitingCount: Int, enabled: Bool, scope: WaitingBeaconScope) {
        self.waitingCount = waitingCount
        isEnabled = enabled
        self.scope = scope
        refresh()
    }

    func refresh() {
        let screens = Self.targetScreens(
            waitingCount: waitingCount, enabled: isEnabled, scope: scope, screens: NSScreen.screens,
            fullScreen: Self.fullScreenDisplays)
        while panels.count > screens.count {
            let panel = panels.removeLast()
            panel.button.setRotating(false)
            panel.orderOut(nil)
        }
        for (index, screen) in screens.enumerated() {
            if index == panels.count {
                panels.append(WaitingBeaconPanel(openWaiting: openWaiting, openSettings: openSettings))
            }
            panels[index].show(waitingCount: waitingCount, on: screen)
        }
    }

    static func targetScreens<Screen>(
        waitingCount: Int, enabled: Bool, scope: WaitingBeaconScope, screens: [Screen],
        fullScreen: ([Screen]) -> [Screen]
    ) -> [Screen] {
        guard enabled, waitingCount > 0 else { return [] }
        return scope == .allModes ? screens : fullScreen(screens)
    }

    @objc private func displayChanged(_ notification: Notification) { refresh() }

    @objc private func spaceChanged(_ notification: Notification) {
        guard isEnabled, waitingCount > 0 else { return }
        refresh()
        // The system announces a space change before its windows reach their final positions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    static func frame(on screen: NSRect, menuHeight: CGFloat, right: Bool, inset: CGFloat) -> NSRect {
        let side = WaitingBeaconButton.side
        return NSRect(
            x: right ? screen.maxX - inset - side : screen.minX + inset,
            y: screen.maxY - menuHeight - 4 - side, width: side, height: side)
    }

    /// The screen another application's windows cover edge to edge, which is what a full-screen
    /// space looks like from outside. Window bounds are readable without screen-recording rights.
    static func fullScreenDisplays(_ screens: [NSScreen]) -> [NSScreen] {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
            let primaryHeight = screens.first?.frame.height
        else {
            return []
        }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let others: [(owner: pid_t, bounds: CGRect)] = windows.compactMap { window in
            guard
                window[kCGWindowLayer as String] as? Int == 0,
                let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != ownProcess,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else {
                return nil
            }
            return (owner, rect)
        }
        return screens.filter { screen in
            isCovered(screen.frame, topInset: screen.safeAreaInsets.top, primaryHeight: primaryHeight, by: others)
        }
    }

    /// Whether one application's windows, taken together, cover the screen edge to edge and top
    /// to bottom — below the notch where the screen has one: measured on macOS 26.5, a
    /// full-screen window there starts under the 33-point band. Together, because a full-screen
    /// window with tabs or a toolbar is two: measured on macOS 15.7.7 with Ghostty 1.3.1, the tab
    /// bar was a window 72 points tall at the top and the terminal another from 28 points down,
    /// and neither covered the screen alone. `frame` is in AppKit's coordinates, the windows'
    /// bounds in the window server's, from the top left of the primary screen.
    static func isCovered(
        _ frame: CGRect, topInset: CGFloat, primaryHeight: CGFloat, by windows: [(owner: pid_t, bounds: CGRect)]
    ) -> Bool {
        let top = primaryHeight - frame.maxY
        let bottom = primaryHeight - frame.minY
        let spanning = windows.filter { window in
            abs(window.bounds.minX - frame.minX) < 1 && abs(window.bounds.width - frame.width) < 1
                && window.bounds.minY >= top - 1 && window.bounds.maxY <= bottom + 1
        }
        return Set(spanning.map(\.owner)).contains { owner in
            // How far down the screen is covered so far; above the notch's band it need not be.
            var reach = top + topInset
            for window in spanning.filter({ $0.owner == owner }).sorted(by: { $0.bounds.minY < $1.bounds.minY }) {
                guard window.bounds.minY <= reach + 1 else {
                    break
                }
                reach = max(reach, window.bounds.maxY)
            }
            return reach >= bottom - 1
        }
    }
}

@MainActor
private final class WaitingBeaconPanel: NSPanel {
    let button: WaitingBeaconButton

    init(openWaiting: @escaping () -> Void, openSettings: @escaping () -> Void) {
        button = WaitingBeaconButton(openSettings: openSettings, openWaiting: openWaiting)
        super.init(
            contentRect: button.bounds, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        contentView = button
    }

    func show(waitingCount: Int, on screen: NSScreen) {
        button.showCount(waitingCount)
        button.setRotating(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let position = ThemeInUse.timing.dot
        button.setDiameter(position.ringDiameter)
        setFrame(
            FullScreenDot.frame(
                on: screen.frame, menuHeight: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top),
                right: position.isOnTheRight, inset: position.inset), display: true)
        orderFrontRegardless()
    }
}

/// A native button so the whole target can be clicked on the first press or activated with VoiceOver.
@MainActor
final class WaitingBeaconButton: NSButton {
    static let side: CGFloat = 44
    private let orbit = CALayer()
    private let light = CALayer()
    private(set) var diameter: CGFloat = WidgetTheme.Timing.Dot().ringDiameter
    private let openSettings: () -> Void
    private let openWaiting: () -> Void

    init(openSettings: @escaping () -> Void = {}, openWaiting: @escaping () -> Void) {
        self.openSettings = openSettings
        self.openWaiting = openWaiting
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        target = self
        action = #selector(openList)
        wantsLayer = true
        orbit.frame = bounds
        light.backgroundColor = NSColor.systemOrange.cgColor
        orbit.addSublayer(light)
        layer?.addSublayer(orbit)
        setDiameter(diameter)
        let options = NSMenu()
        let settings = options.addItem(
            withTitle: "Waiting Beacon Settings…", action: #selector(configure), keyEquivalent: "")
        settings.target = self
        menu = options
        toolTip = "Click to open waiting chats. Right-click for beacon settings."
    }

    func setDiameter(_ value: CGFloat) {
        diameter = value
        let lightSize = value * 7 / 30
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.bounds.size = CGSize(width: lightSize, height: lightSize)
        light.cornerRadius = lightSize / 2
        light.position = CGPoint(x: bounds.midX, y: bounds.midY + value / 2)
        CATransaction.commit()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func configure() { openSettings() }

    @objc private func openList() { openWaiting() }

    func showCount(_ count: Int) {
        title = count > 99 ? "99+" : String(count)
        setAccessibilityLabel(count == 1 ? "1 chat waiting for a reply" : "\(count) chats waiting for a reply")
        needsDisplay = true
    }

    var isRotating: Bool { orbit.animation(forKey: "beacon") != nil }

    func setRotating(_ rotate: Bool) {
        guard rotate != isRotating else { return }
        if rotate {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 2
            turn.repeatCount = .infinity
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            orbit.add(turn, forKey: "beacon")
        } else {
            orbit.removeAnimation(forKey: "beacon")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A transparent window passes clicks through its clear pixels. Keep the full target hittable.
        NSColor.black.withAlphaComponent(0.02).setFill()
        bounds.fill()
        let face = NSBezierPath(
            ovalIn: bounds.insetBy(dx: (bounds.width - diameter) / 2, dy: (bounds.height - diameter) / 2))
        NSColor(white: isHighlighted ? 0.22 : 0.12, alpha: 1).setFill()
        face.fill()
        NSColor.systemOrange.withAlphaComponent(0.85).setStroke()
        face.lineWidth = diameter / 15
        face.stroke()
        let number = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: min(title.count > 2 ? 10 : 13, diameter * (title.count > 2 ? 0.34 : 0.5)), weight: .semibold
                ),
                .foregroundColor: NSColor.white,
            ])
        let size = number.size()
        number.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
