import AppKit
import SwiftUI
import XCTest

@testable import AgentWatchApp

/// A note under a section of the settings window, which a person reads from the left.
@MainActor
final class FootnoteTests: XCTestCase {
    /// A form sets the wrapped lines of its footer to the trailing edge: the Menu section's
    /// three-line note came out ragged on the left, its last line pushed to the right. Seen
    /// by drawing the page; every line of a note now starts at the same place.
    func testEveryLineOfAWrappedNoteStartsAtTheLeft() throws {
        let note = Footnote(String(repeating: "word ", count: 37))
        // A section with no rows, so the note is the only text on the page.
        let page = Form {
            Section {
                EmptyView()
            } footer: {
                note
            }
        }
        let starts = try lineStarts(of: page, width: 300)

        XCTAssertGreaterThanOrEqual(starts.count, 3, "the note did not wrap, so it shows nothing about alignment")
        let spread = (starts.max() ?? 0) - (starts.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 2, "the lines start at \(starts) pixels")
    }

    /// Where each line of text on the page starts, in pixels from the left.
    private func lineStarts(of page: some View, width: CGFloat) throws -> [Int] {
        let hosting = NSHostingView(rootView: page.formStyle(.grouped))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI fills a form in over a few turns of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        // A row is ink where it differs from its own left edge, which is window background; a
        // row inked across most of the width is a box or a rule, not text.
        var starts: [Int] = []
        var line: [Int] = []
        for y in 0..<rep.pixelsHigh {
            let background = try XCTUnwrap(rep.colorAt(x: 1, y: y))
            let inked = (2..<rep.pixelsWide).filter { x in
                guard let colour = rep.colorAt(x: x, y: y) else {
                    return false
                }
                return abs(colour.redComponent - background.redComponent) > 0.15
                    || abs(colour.greenComponent - background.greenComponent) > 0.15
                    || abs(colour.blueComponent - background.blueComponent) > 0.15
            }
            if let first = inked.first, inked.count < rep.pixelsWide * 8 / 10 {
                line.append(first)
            } else if !line.isEmpty {
                starts.append(line.min() ?? 0)
                line = []
            }
        }
        if !line.isEmpty {
            starts.append(line.min() ?? 0)
        }
        return starts
    }
}
