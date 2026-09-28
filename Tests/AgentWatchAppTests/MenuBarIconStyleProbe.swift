import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// Draws the menu bar icon in each of its styles onto strips of bar, for a person to look at.
///
/// Skipped unless `MENU_BAR_RENDER_DIR` names a directory. Four backgrounds, because the bar
/// is not the app's to paint (ADR-0012): dark, light, and two bare wallpaper gradients, which
/// are worse than a real bar and are there to be the worst case. The sphere is drawn at actual
/// size, four times larger, and once at twelve pixels a point to see its shading.
///
///     MENU_BAR_RENDER_DIR=/tmp/render swift test --filter MenuBarIconStyleProbe
@MainActor
final class MenuBarIconStyleProbe: XCTestCase {
    private struct Backdrop {
        let name: String
        let dark: Bool
        let paint: (NSRect) -> Void
    }

    private static let backdrops: [Backdrop] = [
        Backdrop(name: "dark bar", dark: true) {
            NSColor(white: 0.16, alpha: 1).setFill()
            $0.fill()
        },
        Backdrop(name: "light bar", dark: false) {
            NSColor(white: 0.93, alpha: 1).setFill()
            $0.fill()
        },
        Backdrop(name: "warm wallpaper", dark: true) {
            NSGradient(
                starting: NSColor(srgbRed: 0.95, green: 0.62, blue: 0.28, alpha: 1),
                ending: NSColor(srgbRed: 0.72, green: 0.33, blue: 0.20, alpha: 1)
            )?.draw(in: $0, angle: 0)
        },
        Backdrop(name: "cool wallpaper", dark: true) {
            NSGradient(
                starting: NSColor(srgbRed: 0.20, green: 0.36, blue: 0.62, alpha: 1),
                ending: NSColor(srgbRed: 0.40, green: 0.60, blue: 0.82, alpha: 1)
            )?.draw(in: $0, angle: 0)
        },
    ]

    private struct Row {
        let label: String
        let backdrop: Backdrop
        let tiles: [(NSImage?, String)]
    }

    func testDrawTheVariants() throws {
        let requested = ProcessInfo.processInfo.environment["MENU_BAR_RENDER_DIR"]
        try XCTSkipIf(requested == nil, "a drawing probe, not a check: set MENU_BAR_RENDER_DIR")
        let directory = try XCTUnwrap(requested)

        let sphereCounts: [[Int]] = [
            [1, 0, 0, 11], [1, 3, 1, 6], [0, 4, 2, 0], [0, 0, 0, 5], [2, 0, 1, 0], [5, 5, 0, 0], [0, 0, 0, 0],
        ]
        for zoom in [1, 4] {
            var sphereRows: [Row] = []
            for backdrop in zoom == 1 ? Self.backdrops : Array(Self.backdrops.prefix(2)) {
                var tiles: [(NSImage?, String)] = sphereCounts.map { counts in
                    (
                        MenuBarSphereRenderer.draw(cells(counts), dark: backdrop.dark)?.composited(),
                        counts.map(String.init).joined(separator: "/")
                    )
                }
                // The bottom of a breath, which only a sphere with somebody waiting takes.
                tiles.append(
                    (
                        MenuBarSphereRenderer.draw(cells([1, 0, 0, 11]), dark: backdrop.dark)?.composited(phase: 0.5),
                        "breath"
                    )
                )
                sphereRows.append(Row(label: "sphere", backdrop: backdrop, tiles: tiles))
            }
            try write(
                sheet(sphereRows, tileWidth: zoom == 1 ? 44 : 30),
                named: zoom == 1 ? "sphere" : "sphere-zoom",
                in: directory,
                zoom: zoom
            )
        }

        // Straight from the sphere's own bitmap, painted at twelve pixels a point.
        for counts in [[1, 3, 1, 6], [1, 0, 0, 11]] {
            let drawn = try XCTUnwrap(MenuBarSphereRenderer.draw(cells(counts), dark: true, scale: 12))
            let map = try XCTUnwrap(drawn.parts.first?.image.representations.first as? NSBitmapImageRep)
            try XCTUnwrap(map.representation(using: .png, properties: [:]))
                .write(
                    to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("sphere-large-\(counts.map(String.init).joined(separator: "-")).png")
                )
        }

        let subsets: [(String, Set<SessionAttention>)] = [
            ("all four", [.needsPerson, .working, .done, .quiet]),
            ("no idle", [.needsPerson, .working, .done]),
            ("no needs you", [.working, .done, .quiet]),
            ("needs + working", [.needsPerson, .working]),
            ("needs only", [.needsPerson]),
        ]
        let gridCounts: [[Int]] = [[2, 3, 1, 6], [0, 0, 0, 0], [12, 3, 1, 1]]
        var gridRows: [Row] = []
        for (label, shown) in subsets {
            for backdrop in Self.backdrops {
                let tiles: [(NSImage?, String)] = gridCounts.map { counts in
                    (
                        MenuBarIconRenderer.draw(cells(counts, showing: shown), dark: backdrop.dark)?.composited(),
                        counts.map(String.init).joined(separator: "/")
                    )
                }
                gridRows.append(Row(label: label, backdrop: backdrop, tiles: tiles))
            }
        }
        try write(sheet(gridRows, tileWidth: 80), named: "grid", in: directory)
    }

    private func cells(_ counts: [Int], showing shown: Set<SessionAttention> = Set(SessionAttention.counted))
        -> [MenuBarIconCell]
    {
        MenuBarIconCell.cells(
            for: SessionAttentionCounts(needsPerson: counts[0], working: counts[1], done: counts[2], quiet: counts[3]),
            showing: shown
        )
    }

    // MARK: - sheets

    private let labelWidth: CGFloat = 190
    private let rowHeight: CGFloat = 30
    private let captionHeight: CGFloat = 14

    private func sheet(_ rows: [Row], tileWidth: CGFloat) -> NSBitmapImageRep {
        let columns = rows.map(\.tiles.count).max() ?? 0
        let size = NSSize(
            width: labelWidth + CGFloat(columns) * tileWidth,
            height: captionHeight + CGFloat(rows.count) * rowHeight
        )
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white,
        ]
        for (column, caption) in (rows.first?.tiles.map(\.1) ?? []).enumerated() {
            (caption as NSString).draw(
                at: NSPoint(x: labelWidth + CGFloat(column) * tileWidth + 2, y: size.height - captionHeight + 1),
                withAttributes: text
            )
        }
        for (index, row) in rows.enumerated() {
            let top = size.height - captionHeight - CGFloat(index + 1) * rowHeight
            ("\(row.label) — \(row.backdrop.name)" as NSString).draw(
                at: NSPoint(x: 4, y: top + 9),
                withAttributes: text
            )
            let bar = NSRect(
                x: labelWidth, y: top + (rowHeight - 22) / 2, width: CGFloat(columns) * tileWidth, height: 22)
            row.backdrop.paint(bar)
            for (column, tile) in row.tiles.enumerated() {
                guard let image = tile.0 else {
                    continue
                }
                let left = labelWidth + CGFloat(column) * tileWidth + ((tileWidth - image.size.width) / 2).rounded()
                image.draw(in: NSRect(x: left, y: bar.minY, width: image.size.width, height: image.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// `zoom` makes each pixel a block of that many, for reading edges and blends.
    private func write(_ rep: NSBitmapImageRep, named name: String, in directory: String, zoom: Int = 1) throws {
        var output = rep
        if zoom > 1 {
            let width = rep.pixelsWide * zoom
            let height = rep.pixelsHigh * zoom
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.interpolationQuality = .none
            context.draw(try XCTUnwrap(rep.cgImage), in: CGRect(x: 0, y: 0, width: width, height: height))
            output = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        }
        let data = try XCTUnwrap(output.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
