import AgentWatchCore
import AppKit
import XCTest

@testable import AgentWatchApp

/// The README's picture of the menu, taken from a real menu: the system draws most of a menu,
/// so no offscreen drawing can stand in for it.
///
///     MENU_RENDER_DIR=docs/images swift test --filter ReadmeMenuProbe
///
/// Puts an item in the menu bar, opens its menu over the sessions of `ReadmeShowcase` for
/// about a second, and takes only the menu's own window with `screencapture -l`, so nothing
/// else on the screen gets in. Keep the pointer away from where the menu opens: a line under it
/// is drawn highlighted. macOS asks once for Screen Recording permission for the app the
/// command runs from.
@MainActor
final class ReadmeMenuProbe: XCTestCase {
    func testTakeTheMenu() throws {
        guard let directory = ProcessInfo.processInfo.environment["MENU_RENDER_DIR"] else {
            throw XCTSkip("Set MENU_RENDER_DIR to take the README's picture of the menu")
        }
        // The menu opens on the display with the menu bar and is taken at that display's scale.
        guard NSScreen.main?.backingScaleFactor == 2 else {
            return XCTFail(
                "the main display draws at \(NSScreen.main?.backingScaleFactor ?? 0)x; make a Retina one main")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let settings = WidgetSettingsStore(preferences: try isolatedPreferences())
        for attention in SessionAttention.counted {
            settings.setMenuLists(attention, true)
        }
        var ordering = SessionOrdering()
        let host = FakeAppHost()
        host.sessions = ordering.order(
            ReadmeShowcase.sessions(), mode: .attention, blocks: SessionBlock.defaultOrder, now: ReadmeShowcase.now)
        host.attentionCounts = SessionAttentionCounts(sessions: host.sessions)
        let menu = StatusMenu(settings: settings, host: host)
        // The icon installed the way `AppDelegate.applyMenuBarIcon` installs it.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = MenuBarIconView()
        icon.onLengthChange = { item.length = $0 }
        let button = try XCTUnwrap(item.button)
        XCTAssertTrue(icon.show(MenuBarIconCell.cells(for: host.attentionCounts), as: .counts))
        button.addSubview(icon)
        if let length = icon.itemLength {
            item.length = length
        }
        icon.fill(button)
        item.menu = menu.menu
        defer { NSStatusBar.system.removeStatusItem(item) }

        let file = URL(fileURLWithPath: directory).appendingPathComponent("menu.png")
        var status: Int32?
        // In the common modes, because the open menu runs the loop in its tracking mode.
        let take = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                status = Self.capture(menuWindowOf: getpid(), to: file)
                menu.menu.cancelTracking()
            }
        }
        RunLoop.main.add(take, forMode: .common)
        item.button?.performClick(nil)
        XCTAssertEqual(status, 0, "screencapture failed; is Screen Recording allowed for this terminal?")
        try cropToTheMenu(file)
        print("took \(file.path)")
    }

    /// The menu's window also holds a copy of the status item above the menu, drawn for a dark
    /// menu bar: white numbers that vanish on a light page. The README shows the icon on its
    /// own, so the picture starts where the menu does — the first opaque row down its middle.
    private func cropToTheMenu(_ file: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let rep = NSBitmapImageRep(cgImage: image)
        let top = try XCTUnwrap(
            (0..<rep.pixelsHigh).first { (rep.colorAt(x: rep.pixelsWide / 2, y: $0)?.alphaComponent ?? 0) > 0.9 },
            "no opaque row: the capture holds no menu")
        let menu = try XCTUnwrap(
            image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: image.height - top)))
        try XCTUnwrap(NSBitmapImageRep(cgImage: menu).representation(using: .png, properties: [:])).write(to: file)
    }

    /// The exit status of `screencapture` for this process's menu window, or -1 when no such
    /// window is on screen. `-o` leaves the shadow out, so the corners stay transparent.
    private static func capture(menuWindowOf pid: pid_t, to file: URL) -> Int32 {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard
            let window = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                    && ($0[kCGWindowLayer as String] as? Int) == menuLevel
            }),
            let number = window[kCGWindowNumber as String] as? Int
        else {
            return -1
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(number), file.path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            print(
                "screencapture: \(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        }
        return process.terminationStatus
    }
}
