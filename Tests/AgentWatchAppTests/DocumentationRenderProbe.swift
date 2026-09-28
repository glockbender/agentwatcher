import AgentWatchCore
import AgentWatchTestSupport
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AgentWatchApp

/// Real compact widget views with fictional sessions and the shipped palette.
/// Animation samples use the lamp's actual Core Animation endpoints, duration and easing.
@MainActor
final class DocumentationRenderProbe: XCTestCase {
    private let width: CGFloat = 339
    private let style = WidgetStyle(scale: 0.9)

    func testRenderReadmeAssets() throws {
        guard let directory = ProcessInfo.processInfo.environment["DOC_RENDER_DIR"] else {
            throw XCTSkip("Set DOC_RENDER_DIR to generate README images")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: directory)
        let frames = 240
        let fps = 12.0
        let gif = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                root.appendingPathComponent("widget-demo.gif") as CFURL, UTType.gif.identifier as CFString, frames, nil)
        )
        CGImageDestinationSetProperties(
            gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let now = Date(timeIntervalSince1970: 100_000)
        var ordering = SessionOrdering()
        for frame in 0..<frames {
            let time = Double(frame) / fps
            let stage = Int(time / 4)
            let cast = sessions(stage: stage, now: now)
            let sorted = ordering.order(cast, mode: .blocks, blocks: SessionBlock.defaultOrder, now: now)
            if stage == 1 { XCTAssertEqual(sorted.first?.title, "Catalog") }
            let list = HUDSessionListView(
                models: sorted.map { HUDRowModel(snapshot: $0, now: now, layout: .standard) }, usageLimits: [],
                now: now, availableWidth: width, focus: { _ in }, remove: { _ in },
                background: .defaultBackground, lampScheme: LampScheme(),
                backgroundOpacity: WidgetBackgroundStore.defaultOpacity, style: style,
                restoredScrollOffset: nil, onScroll: { _ in })
            let height = HUDSessionListView.selfSizedHeight(
                sessionCount: cast.count, usageLimits: [],
                background: .defaultBackground, style: style)
            let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 56))
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = NSColor(sRGB: "#F4F6F8").cgColor
            list.frame = NSRect(x: 0, y: 0, width: width, height: height)
            canvas.addSubview(list)
            let titles = [
                "Different rhythms, one glance", "Catalog becomes active ↑", "Catalog needs your answer",
                "Catalog has finished", "Catalog is inactive again ↓",
            ]
            let subtitles = [
                "Work pulses. Requests alternate orange and yellow.", "The project moves from Inactive to Active.",
                "A fast orange ↔ yellow signal asks for attention.", "A steady light means this turn is complete.",
                "No signal: the project returns below active work.",
            ]
            for (text, y, size, weight) in [
                (titles[stage], height + 29, CGFloat(14), NSFont.Weight.semibold),
                (subtitles[stage], height + 8, CGFloat(10), NSFont.Weight.regular),
            ] {
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: size, weight: weight)
                label.textColor = NSColor(sRGB: "#23303D")
                label.frame = NSRect(x: 6, y: y, width: width - 12, height: 21)
                canvas.addSubview(label)
            }
            canvas.layoutSubtreeIfNeeded()
            sampleAnimations(in: list, at: time)
            if frame == 0 {
                let widget = try bitmap(list)
                try XCTUnwrap(widget.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("widget.png"))
            }
            let image = try XCTUnwrap(bitmap(canvas).cgImage)
            if frame.isMultiple(of: 48) || frame == 50 {
                let png = NSBitmapImageRep(cgImage: image)
                try XCTUnwrap(png.representation(using: .png, properties: [:])).write(
                    to: root.appendingPathComponent("demo-frame-\(frame).png"))
            }
            CGImageDestinationAddImage(
                gif, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(gif))
    }

    private func sessions(stage: Int, now: Date) -> [SessionSnapshot] {
        let phase: SessionPhase = [.disconnected, .executing, .waitingForUser, .completed, .disconnected][stage]
        return [
            testSession(index: 0, title: "API tests", phase: .executing, lastObservedAt: now - 20),
            testSession(
                index: 1, source: .codex, title: "Release review", phase: .waitingForUser,
                userInputRequestKind: .approval, lastObservedAt: now - 10),
            testSession(index: 2, title: "Search plan", phase: .planning, lastObservedAt: now - 30),
            testSession(
                index: 3, source: .codex, title: "Catalog", phase: phase,
                userInputRequestKind: phase == .waitingForUser ? .approval : nil,
                lastObservedAt: stage == 0 || stage == 4 ? now - 3600 : now),
            testSession(index: 4, title: "Sync failed", phase: .failed, lastObservedAt: now - 120),
        ]
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
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
