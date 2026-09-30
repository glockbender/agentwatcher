import AgentWatchCore
import AppKit

/// A small dot in a top corner of a full-screen display, as macOS shows one for the
/// microphone: the menu bar — and the sphere in it — is hidden there, and this is what is left.
///
/// Shown only while something needs a person or is working, and only on a screen a full-screen
/// window covers. It cycles through the theme colour of every state that holds sessions, each
/// for its share of them. Checked when the space or the frontmost
/// application changes and when the counts move, never on a timer. Steps aside while the pointer
/// is in the menu bar, which the system slides down over the dot, and returns a second after.
@MainActor
final class FullScreenDot {
    private static var motion: WidgetTheme.Motion { WidgetTheme.motion }

    private let panel: NSPanel
    private let dot = NSView()
    private var counts = SessionAttentionCounts(needsPerson: 0, working: 0, done: 0, quiet: 0)
    private var isEnabled = true
    private var observers: [NSObjectProtocol] = []
    private var pointerMonitor: Any?
    private var screenFrame: NSRect?
    private var menuBarHeight: CGFloat = 0
    private var menuBarShown = false
    private var comeBack: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 8, height: 8),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        dot.wantsLayer = true
        panel.contentView = dot
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshAfterTheMove() }
                })
        }
    }

    func show(_ counts: SessionAttentionCounts, enabled: Bool) {
        self.counts = counts
        isEnabled = enabled
        refresh()
    }

    func refresh() {
        let active = counts.count(of: .needsPerson) > 0 || counts.count(of: .working) > 0
        guard isEnabled, active, let screen = Self.fullScreenDisplay() else {
            stopWatchingPointer()
            panel.orderOut(nil)
            return
        }
        watchPointer(on: screen)
        guard !menuBarShown else {
            panel.orderOut(nil)
            return
        }
        let shares = SessionAttention.counted.compactMap { state -> (NSColor, Double)? in
            let count = counts.count(of: state)
            return count > 0 ? (state.accent, Double(count)) : nil
        }
        let diameter = Self.motion.dotDiameter
        dot.layer?.cornerRadius = diameter / 2
        show(Self.cycle(shares, fade: Self.motion.dotFadeShare), on: dot.layer)
        panel.setFrame(
            NSRect(origin: Self.origin(on: screen), size: NSSize(width: diameter, height: diameter)), display: true)
        panel.orderFrontRegardless()
    }

    /// Each state's colour for its share of the sessions, fading into the next, over one cycle:
    /// the keyframe times and colours, starting and ending on the first so the loop is seamless.
    static func cycle(_ shares: [(NSColor, Double)], fade: Double = 0.3) -> [(time: Double, color: NSColor)] {
        let total = shares.map(\.1).reduce(0, +)
        guard let first = shares.first, total > 0 else {
            return []
        }
        var frames: [(time: Double, color: NSColor)] = []
        var start = 0.0
        for (color, count) in shares {
            let span = count / total
            frames.append((start, color))
            frames.append((start + span * (1 - fade), color))
            start += span
        }
        frames.append((1, first.0))
        return frames
    }

    private func show(_ frames: [(time: Double, color: NSColor)], on layer: CALayer?) {
        guard let layer, let first = frames.first else {
            return
        }
        layer.removeAnimation(forKey: "cycle")
        layer.backgroundColor = first.color.cgColor
        guard Set(frames.map { $0.color.srgbHex ?? "" }).count > 1 else {
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "backgroundColor")
        animation.values = frames.map(\.color.cgColor)
        animation.keyTimes = frames.map { NSNumber(value: $0.time) }
        animation.duration = Self.motion.dotCycleSeconds
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        layer.add(animation, forKey: "cycle")
    }

    /// Now and again once the move has settled: a space change is announced as it starts, and
    /// the full-screen window it brings is not yet where it will be.
    private func refreshAfterTheMove() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refresh()
        }
    }

    private func watchPointer(on screen: NSScreen) {
        screenFrame = screen.frame
        menuBarHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        guard pointerMonitor == nil else {
            return
        }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    private func stopWatchingPointer() {
        if let pointerMonitor {
            NSEvent.removeMonitor(pointerMonitor)
        }
        pointerMonitor = nil
        screenFrame = nil
        comeBack?.cancel()
        comeBack = nil
        menuBarShown = false
    }

    private func pointerMoved() {
        guard let screenFrame else {
            return
        }
        if Self.isInMenuBar(NSEvent.mouseLocation, screen: screenFrame, height: menuBarHeight) {
            comeBack?.cancel()
            comeBack = nil
            if !menuBarShown {
                menuBarShown = true
                panel.orderOut(nil)
            }
        } else if menuBarShown, comeBack == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.menuBarShown = false
                self?.comeBack = nil
                self?.refresh()
            }
            comeBack = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    static func isInMenuBar(_ point: NSPoint, screen: NSRect, height: CGFloat) -> Bool {
        point.x >= screen.minX && point.x < screen.maxX && point.y <= screen.maxY && point.y >= screen.maxY - height
    }

    /// In the corner the theme names, beside the notch where the screen has one — in the band the
    /// system leaves unobscured — and in the screen's own corner otherwise.
    static func origin(on screen: NSScreen) -> NSPoint {
        let diameter = motion.dotDiameter
        let inset = motion.dotInset
        let right = motion.dotCorner == "topRight"
        let band = right ? screen.auxiliaryTopRightArea : screen.auxiliaryTopLeftArea
        let area =
            band.flatMap { $0.height > diameter ? $0 : nil }
            ?? NSRect(
                x: screen.frame.minX, y: screen.frame.maxY - 2 * inset - diameter, width: screen.frame.width,
                height: 2 * inset + diameter)
        return NSPoint(x: right ? area.maxX - inset - diameter : area.minX + inset, y: area.midY - diameter / 2)
    }

    /// The screen another application's window covers edge to edge, which is what a full-screen
    /// space looks like from outside — below the notch where the screen has one: measured on
    /// macOS 26.5, a full-screen window there starts under the 33-point band. Window bounds are
    /// readable without screen-recording rights.
    static func fullScreenDisplay() -> NSScreen? {
        guard
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
            let primaryHeight = NSScreen.screens.first?.frame.height
        else {
            return nil
        }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let covered: [CGRect] = windows.compactMap { window in
            guard
                window[kCGWindowLayer as String] as? Int == 0,
                window[kCGWindowOwnerPID as String] as? Int32 != ownProcess,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else {
                return nil
            }
            return rect
        }
        return NSScreen.screens.first { screen in
            let frame = screen.frame
            let top = primaryHeight - frame.maxY
            let bottom = primaryHeight - frame.minY
            return covered.contains { window in
                abs(window.minX - frame.minX) < 1 && abs(window.width - frame.width) < 1
                    && abs(window.maxY - bottom) < 1
                    && window.minY - top <= screen.safeAreaInsets.top + 1
                    && window.height >= frame.height - screen.safeAreaInsets.top - 1
            }
        }
    }
}
