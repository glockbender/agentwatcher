import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import AgentWatchApp

/// Draws the README's pictures from the real views and the invented sessions of
/// `ReadmeShowcase`, into `DOC_RENDER_DIR`. `task readme-images` runs it into `docs/images`.
///
/// Offscreen: nothing appears on screen and nothing takes the focus. The menu is the one
/// picture it cannot draw, since the system draws most of a menu; `ReadmeMenuProbe` takes
/// that one from a real menu.
@MainActor
final class DocumentationRenderProbe: XCTestCase {
    private let now = ReadmeShowcase.now

    func testDrawTheWidgetPictures() throws {
        let root = try outputDirectory()
        let afternoon = ReadmeShowcase.sessions()
        let byState = ordered(afternoon, by: .attention)
        try write(widget(byState, width: 380, usage: ReadmeShowcase.usageLimits), "widget", in: root)
        try write(hoverCard(for: afternoon[2]), "card", in: root)

        // The looks: one theme in its two modes, and a theme of somebody's own.
        let four = Array(byState.prefix(4))
        try write(widget(four, width: 330, look: WidgetTheme.standard.dark), "look-dark", in: root)
        try write(widget(four, width: 330, look: WidgetTheme.standard.light), "look-light", in: root)
        try write(widget(four, width: 330, look: Self.ownTheme), "look-own", in: root)
        try write(widget(four, width: 270, style: WidgetStyle(scale: 0.75)), "size-75", in: root)
        try write(widget(four, width: 450, style: WidgetStyle(scale: 1.5)), "size-150", in: root)

        // What a row shows: the least and the most it can.
        let three = Array(byState.prefix(3))
        try write(widget(three, width: 260, layout: RowLayout(parts: [.lamp, .name])), "row-minimal", in: root)
        let everything = RowLayout(
            parts: [.timer, .lamp, .agent, .name, .project, .branch, .gap, .model, .counters, .context],
            flexible: .name)
        try write(widget(three, width: 620, layout: everything), "row-full", in: root)

        // The same afternoon in three of the four orders; the fourth moves on every event.
        let orders: [(SessionOrder, String)] = [(.arrival, "arrival"), (.attention, "state"), (.blocks, "blocks")]
        for (order, name) in orders {
            let rows = RowLayout(parts: [.lamp, .agent, .name])
            try write(widget(ordered(afternoon, by: order), width: 280, layout: rows), "order-\(name)", in: root)
        }

        for style in MenuBarIconStyle.allCases {
            try write(menuBarIcon(afternoon, style: style), "menubar-\(style.rawValue)", in: root)
        }
    }

    /// Every lamp at its own rhythm, one row each, named by what it means.
    ///
    /// Thirty seconds, so the loop closes on a whole cycle of every lamp but the 2.8-second
    /// ring, which steps once per loop.
    func testDrawTheLampLegend() throws {
        let root = try outputDirectory()
        let fps = 10.0
        let frames = 300
        let gif = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                root.appendingPathComponent("lamps.gif") as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(
            gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let legend = ReadmeShowcase.legend()
        for frame in 0..<frames {
            let list = widget(legend, width: 300, layout: RowLayout(parts: [.lamp, .name]))
            let canvas = framed(list, padding: 12, color: NSColor(sRGB: "#F4F6F8"))
            sampleAnimations(in: list, at: Double(frame) / fps)
            let image = try XCTUnwrap(bitmap(canvas).cgImage)
            CGImageDestinationAddImage(
                gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))
    }

    /// The settings pages the README points at, in the light appearance.
    func testDrawTheSettingsPages() throws {
        let root = try outputDirectory()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWatchThemes.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let preferences = try isolatedPreferences()
        let settings = WidgetSettingsStore(preferences: preferences)
        let themes = ThemeStore(preferences: preferences, folder: folder) { try FileManager.default.removeItem(at: $0) }
        let model = SettingsModel(
            themes: themes, settings: settings, rowLayouts: RowLayoutStore(preferences: preferences),
            shortcuts: FakeShortcutRegistrar.controller(for: settings), host: FakeAppHost(), version: nil)

        try write(page(AnyView(RowPane(model: model)), height: 1000), "settings-rows", in: root, trimming: true)
        try write(page(AnyView(OrderPane(model: model)), height: 1000), "settings-order", in: root, trimming: true)
        try write(page(AnyView(MenuBarPane(model: model)), height: 1000), "settings-menu-bar", in: root, trimming: true)
        // Down to the lamps: the menu bar's colours below them are a second table of the same kind.
        try write(page(AnyView(ThemeEditorPane(model: model)), height: 985), "settings-theme", in: root)
    }

    // MARK: - Scenes

    /// A dark theme somebody made: its own panel, and its own lamps for planning, work, a
    /// question and done.
    private static var ownTheme: WidgetTheme.Look {
        var lamps = LampScheme()
        lamps.setColor(NSColor(sRGB: "#C6A0F6"), for: .planning)
        lamps.setColor(NSColor(sRGB: "#A6DA95"), for: .executing)
        lamps.setColor(NSColor(sRGB: "#F5A97F"), for: .waitingForUser)
        lamps.setColor(NSColor(sRGB: "#8AADF4"), for: .completed)
        return WidgetTheme.Look(background: "#24273A", lamps: WidgetTheme.lamps(from: lamps))
    }

    private func ordered(_ sessions: [SessionSnapshot], by order: SessionOrder) -> [SessionSnapshot] {
        var ordering = SessionOrdering()
        return ordering.order(sessions, mode: order, blocks: SessionBlock.defaultOrder, now: now)
    }

    private func widget(
        _ sessions: [SessionSnapshot],
        width: CGFloat,
        layout: RowLayout = .standard,
        look: WidgetTheme.Look = WidgetTheme.standard.dark,
        style: WidgetStyle = .standard,
        usage: [AgentUsageLimits] = []
    ) -> HUDSessionListView {
        let background = look.widgetBackground
        let list = HUDSessionListView(
            models: sessions.map { HUDRowModel(snapshot: $0, now: now, layout: layout) },
            usageLimits: usage, now: now, availableWidth: width, focus: { _ in }, remove: { _ in },
            background: background, lampScheme: look.lampScheme, backgroundOpacity: 1, style: style,
            restoredScrollOffset: nil, onScroll: { _ in })
        let height = HUDSessionListView.selfSizedHeight(
            sessionCount: sessions.count, usageLimits: usage, background: background, style: style)
        place(list, size: NSSize(width: width, height: height))
        return list
    }

    /// Built the way `SessionHoverCard` builds it.
    private func hoverCard(for snapshot: SessionSnapshot) -> NSView {
        let style = WidgetStyle.standard
        let label = NSTextField(
            labelWithString: hoverCardText(for: snapshot, now: now, layout: .standard, reach: .anApplication))
        label.font = style.secondaryFont
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        let padding = style.hoverCardPadding
        let available = style.hoverCardMaximumWidth - 2 * padding
        label.preferredMaxLayoutWidth = available
        let size = label.sizeThatFits(NSSize(width: available, height: CGFloat.greatestFiniteMagnitude))
        let card = NSView(
            frame: NSRect(x: 0, y: 0, width: size.width + 2 * padding, height: size.height + 2 * padding))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1).cgColor
        card.layer?.cornerRadius = WidgetStyle.panelCornerRadius
        label.frame = NSRect(x: padding, y: padding, width: size.width, height: size.height)
        card.addSubview(label)
        place(card, size: card.frame.size)
        return card
    }

    /// The status item's drawing on a strip the colour of a dark menu bar.
    private func menuBarIcon(_ sessions: [SessionSnapshot], style: MenuBarIconStyle) -> NSView {
        let icon = MenuBarIconView()
        var length = MenuBarIconMetrics.barHeight
        icon.onLengthChange = { length = $0 }
        icon.show(MenuBarIconCell.cells(for: SessionAttentionCounts(sessions: sessions)), as: style)
        // The sphere asks for `NSStatusItem.squareLength`, a negative marker rather than a width.
        if length < 0 {
            length = MenuBarIconMetrics.barHeight
        }
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: length + 16, height: MenuBarIconMetrics.barHeight + 4))
        strip.wantsLayer = true
        strip.layer?.backgroundColor = NSColor(sRGB: "#2B2D31").cgColor
        strip.layer?.cornerRadius = 6
        icon.frame = NSRect(x: 8, y: 2, width: length, height: MenuBarIconMetrics.barHeight)
        strip.addSubview(icon)
        place(strip, size: strip.frame.size)
        return strip
    }

    /// A settings page, drawn taller than it needs: a form cannot say how tall it is.
    private func page(_ root: AnyView, height: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: root.formStyle(.grouped))
        hosting.appearance = NSAppearance(named: .aqua)
        place(hosting, size: NSSize(width: 570, height: height))
        // SwiftUI fills a form in over a few turns of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        return hosting
    }

    private func framed(_ view: NSView, padding: CGFloat, color: NSColor) -> NSView {
        let canvas = NSView(
            frame: NSRect(
                x: 0, y: 0, width: view.frame.width + 2 * padding, height: view.frame.height + 2 * padding))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = color.cgColor
        if let window = view.window, window.contentView === view {
            window.contentView = nil
        }
        view.frame.origin = NSPoint(x: padding, y: padding)
        canvas.addSubview(view)
        place(canvas, size: canvas.frame.size)
        return canvas
    }

    // MARK: - Drawing

    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["DOC_RENDER_DIR"] else {
            throw XCTSkip("Set DOC_RENDER_DIR to draw the README's pictures")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath: directory)
    }

    private func write(_ view: NSView, _ name: String, in root: URL, trimming: Bool = false) throws {
        var image = try XCTUnwrap(bitmap(view).cgImage)
        if trimming {
            image = trimmedBottom(image)
        }
        let url = root.appendingPathComponent("\(name).png")
        let png = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(png.representation(using: .png, properties: [:])).write(to: url)
        print("drew \(url.lastPathComponent) at \(image.width)×\(image.height)")
    }

    /// Two pixels per point, or the probe fails: on a one-pixel display an offscreen window
    /// draws at one, and such pictures look soft on every Retina screen that opens the README.
    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        XCTAssertEqual(
            CGFloat(bitmap.pixelsWide), 2 * view.bounds.width,
            "drawn at \(view.window?.backingScaleFactor ?? 0)x: run it with a Retina display as the main one")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// The image without the rows at its bottom that are all the colour of its last pixel, but
    /// for a margin: the empty strip under a form drawn taller than it is.
    private func trimmedBottom(_ image: CGImage, margin: Int = 40) -> CGImage {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
        else {
            return image
        }
        let rowBytes = image.bytesPerRow
        let blank = (image.height - 1) * rowBytes
        func isBlank(_ row: Int) -> Bool {
            let start = row * rowBytes
            for offset in stride(from: 0, to: image.width * 4, by: 4) {
                for channel in 0..<4 where abs(Int(bytes[start + offset + channel]) - Int(bytes[blank + channel])) > 2 {
                    return false
                }
            }
            return true
        }
        var bottom = image.height - 1
        while bottom > 0, isBlank(bottom) {
            bottom -= 1
        }
        let height = min(image.height, bottom + 1 + margin)
        return image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: height)) ?? image
    }

    /// A window, because a view outside one lays out against nothing.
    private func place(_ view: NSView, size: NSSize) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
    }

    /// Freeze each real lamp at a frame time; cacheDisplay otherwise captures only the model layer.
    private func sampleAnimations(in view: NSView, at time: Double) {
        if let lamp = view as? SessionLampView, let layer = lamp.layer,
            let animation = layer.animation(forKey: "lamp") as? CABasicAnimation
        {
            let half = animation.duration
            let leg = time.truncatingRemainder(dividingBy: 2 * half) / half
            let progress = CGFloat(leg <= 1 ? leg : 2 - leg)
            let eased = easing(progress, animation.timingFunction)
            layer.removeAnimation(forKey: "lamp")
            if animation.keyPath == "opacity", let from = animation.fromValue as? NSNumber,
                let to = animation.toValue as? NSNumber
            {
                layer.opacity = Float(from.doubleValue + (to.doubleValue - from.doubleValue) * Double(eased))
            } else if let from = animation.fromValue, let to = animation.toValue,
                CFGetTypeID(from as CFTypeRef) == CGColor.typeID,
                CFGetTypeID(to as CFTypeRef) == CGColor.typeID,
                let first = NSColor(cgColor: from as! CGColor), let second = NSColor(cgColor: to as! CGColor),
                let color = first.blended(withFraction: eased, of: second)
            {
                layer.setValue(color.cgColor, forKeyPath: animation.keyPath ?? "backgroundColor")
            }
        }
        for child in view.subviews { sampleAnimations(in: child, at: time) }
    }

    private func easing(_ x: CGFloat, _ function: CAMediaTimingFunction?) -> CGFloat {
        guard let function else { return x }
        var first: [Float] = [0, 0]
        var second: [Float] = [0, 0]
        function.getControlPoint(at: 1, values: &first)
        function.getControlPoint(at: 2, values: &second)
        func curve(_ t: CGFloat, _ a: Float, _ b: Float) -> CGFloat {
            3 * (1 - t) * (1 - t) * t * CGFloat(a) + 3 * (1 - t) * t * t * CGFloat(b) + t * t * t
        }
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if curve(middle, first[0], second[0]) < x { low = middle } else { high = middle }
        }
        return curve((low + high) / 2, first[1], second[1])
    }
}
