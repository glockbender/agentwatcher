import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

@MainActor
final class LayoutProbe: XCTestCase {
    func testLayoutPasses() {
        let now = Date()
        let sessions = (0..<6).map { index in
            testSession(
                index: index, title: "Сессия \(index)", phase: .executing,
                clientKind: .cli, lastObservedAt: now)
        }
        let list = HUDSessionListView(
            sessions: sessions, usageLimits: [], now: now, availableWidth: 300,
            showsSessionTopic: true, focus: { _ in }, remove: { _ in },
            background: .graphite, lampScheme: LampScheme(), backgroundOpacity: 1,
            restoredScrollOffset: nil, onScroll: { _ in })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = list

        // Heights chosen so the overflow counter has to change on every step: 6 rows fit at
        // 200, none at 40. If a constraint change inside `layout()` re-enters the layout
        // engine, this is where it shows.
        for height in [200.0, 40.0, 200.0, 40.0, 200.0, 60.0, 200.0] {
            let started = Date()
            window.setContentSize(NSSize(width: 300, height: height))
            list.layoutSubtreeIfNeeded()
            let elapsed = Int(-started.timeIntervalSinceNow * 1000)
            print("PROBE height=\(Int(height)) hidden=\(list.hiddenSessionCount) \(elapsed) мс")
        }
    }
}
