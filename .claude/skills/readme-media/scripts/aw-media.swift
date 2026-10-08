// aw-media: the hands and eyes of a README take, one subcommand each. Built on first use by the
// `aw-media` wrapper beside this file; nothing here is part of the app.
//
//   check                         the three permissions a take needs, for the process that runs it
//   screen                        main screen: scale (recording pixels per point), menu bar height,
//                                 width and height in points
//   onscreen                      owners of the normal windows on the current desktop, one a line
//   bar                           status items: x width pid owner, in points
//   quit <pid>                    ask an app to quit, as the Dock's Quit does
//   backdrop x y w h              a plain black window in points from the top left, until killed
//   clear-notifications           close every notification on screen, by its own Close action
//   ax find|findc <pid> <text>    first element whose text ends with / contains <text>:
//                                 centre x y, then x y w h, in points from the top left
//   ax press <pid> <text>         press the first element whose identifier or title is <text>
//   ax dismiss <pid> [keep …]     press every row's "×" except on rows whose text holds a kept name
//   ax windows <pid>              frame and title of every window
//   ax close <pid> <title>        press the close button of the window whose title ends with it
//   ax move <pid> <title|-> x y w h   set a window's frame; "-" is the untitled one (the widget)
//   activate <pid>                bring an app forward
//   glide x y [click]             move the pointer along an eased path, then click if asked
//   key <code> [cmd,opt,ctrl,shift]  press and release one key (53 is Escape, 13 is W)
//   space left|right              Control-arrow: the next desktop
//   zoom <stage dir> <keys> <out dir> <width> <height> <fps>
//                                 render s0001.png… through moving crop rects into f0001.png…
import AppKit
import ApplicationServices
import CoreImage
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(element) { return true }
    guard depth < 40 else { return false }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if walk(child, depth: depth + 1, visit) { return true }
    }
    return false
}

func text(_ element: AXUIElement) -> String {
    [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        .compactMap { attribute(element, $0) as? String }.joined(separator: " ")
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else {
        return nil
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func ax(_ args: [String]) {
    guard args.count >= 2, let pid = pid_t(args[1]) else { fail("ax <command> <pid> …") }
    let app = AXUIElementCreateApplication(pid)
    switch args[0] {
    case "find", "findc":
        guard args.count == 3 else { fail("ax find <pid> <text>") }
        var hit: CGRect?
        _ = walk(app) { element in
            let t = text(element)
            guard args[0] == "findc" ? t.contains(args[2]) : t.hasSuffix(args[2]), let f = frame(element) else {
                return false
            }
            hit = f
            return true
        }
        guard let f = hit else { fail("none: \(args[2])") }
        print(Int(f.midX), Int(f.midY), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
    case "press":
        var found: AXUIElement?
        _ = walk(app) { element in
            let id = attribute(element, kAXIdentifierAttribute) as? String
            let title = attribute(element, kAXTitleAttribute) as? String
            guard id == args[2] || title == args[2] else { return false }
            found = element
            return true
        }
        guard let element = found else { fail("none: \(args[2])") }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { fail("press failed") }
    case "dismiss":
        // A restarted copy shows every agent process again, the demo's own sessions among them.
        let keep = Array(args.dropFirst(2))
        func rowText(_ button: AXUIElement) -> String {
            guard let row = attribute(button, kAXParentAttribute) else { return "" }
            var parts: [String] = []
            _ = walk(row as! AXUIElement) { parts.append(text($0)); return false }
            return parts.joined(separator: " ")
        }
        var pressed = 0
        for _ in 0..<80 {
            var button: AXUIElement?
            _ = walk(app) { element in
                guard (attribute(element, kAXRoleAttribute) as? String) == "AXButton",
                    (attribute(element, kAXTitleAttribute) as? String) == "×",
                    !keep.contains(where: { rowText(element).contains($0) })
                else { return false }
                button = element
                return true
            }
            guard let found = button else { break }
            AXUIElementPerformAction(found, kAXPressAction as CFString)
            pressed += 1
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("dismissed \(pressed)")
    case "windows":
        for window in attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            let f = frame(window) ?? .zero
            print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height), (attribute(window, kAXTitleAttribute) as? String) ?? "")
        }
    case "close":
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard let window = windows.first(where: { ((attribute($0, kAXTitleAttribute) as? String) ?? "").hasSuffix(args[2]) }),
            let button = attribute(window, kAXCloseButtonAttribute)
        else { fail("no window: \(args[2])") }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    case "move":
        guard args.count == 7, let x = Double(args[3]), let y = Double(args[4]), let w = Double(args[5]),
            let h = Double(args[6])
        else { fail("ax move <pid> <title|-> x y w h") }
        let want = args[2] == "-" ? "" : args[2]
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard
            let window = windows.first(where: {
                let title = (attribute($0, kAXTitleAttribute) as? String) ?? ""
                return want.isEmpty ? title.isEmpty : title.hasSuffix(want)
            })
        else { fail("no window: \(args[2])") }
        var size = CGSize(width: w, height: h)
        var point = CGPoint(x: x, y: y)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
    default:
        fail("ax: unknown \(args[0])")
    }
}

// MARK: - Input

func post(_ type: CGEventType, _ at: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
}

/// An eased path: a jump straight to the target can miss a hover state the click depends on.
func glide(to target: CGPoint, click: Bool) {
    let start = CGEvent(source: nil)!.location
    let steps = 45
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        post(.mouseMoved, CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e))
        usleep(14_000)
    }
    guard click else { return }
    usleep(250_000)
    post(.leftMouseDown, target)
    usleep(90_000)
    post(.leftMouseUp, target)
}

func flags(_ names: String) -> CGEventFlags {
    var result: CGEventFlags = []
    for name in names.split(separator: ",") {
        switch name {
        case "cmd": result.insert(.maskCommand)
        case "opt": result.insert(.maskAlternate)
        case "ctrl": result.insert(.maskControl)
        case "shift": result.insert(.maskShift)
        default: fail("unknown modifier \(name)")
        }
    }
    return result
}

func press(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}

// MARK: - Windows

func windowList() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
}

func bounds(_ window: [String: Any]) -> CGRect {
    CGRect(dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary)!
}

// MARK: - Zoom

struct Key {
    let t, x, y, w: Double
}

/// Keyframes are "t x y w" in stage pixels from the top left; a pair with the same rect is a
/// hold, and between two different ones the rect moves with smoothstep easing.
func zoom(_ args: [String]) throws {
    guard args.count == 6, let outW = Double(args[3]), let outH = Double(args[4]), let fps = Double(args[5]) else {
        fail("zoom <stage dir> <keys> <out dir> <width> <height> <fps>")
    }
    let keys: [Key] = try String(contentsOfFile: args[1], encoding: .utf8)
        .split(separator: "\n")
        .map { $0.split(separator: "#", omittingEmptySubsequences: false)[0].split(separator: " ").compactMap { Double($0) } }
        .filter { $0.count == 4 }
        .map { Key(t: $0[0], x: $0[1], y: $0[2], w: $0[3]) }
    guard !keys.isEmpty else { fail("no keyframes in \(args[1])") }
    func rect(at t: Double) -> Key {
        if t <= keys[0].t { return keys[0] }
        guard let i = keys.lastIndex(where: { $0.t <= t }), i + 1 < keys.count else { return keys[keys.count - 1] }
        let a = keys[i]
        let b = keys[i + 1]
        var p = (t - a.t) / (b.t - a.t)
        p = p * p * (3 - 2 * p)
        return Key(t: t, x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p, w: a.w + (b.w - a.w) * p)
    }
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CIContext(options: [.workingColorSpace: sRGB])
    let stage = URL(fileURLWithPath: args[0])
    let out = URL(fileURLWithPath: args[2])
    let frames = try FileManager.default.contentsOfDirectory(atPath: stage.path)
        .filter { $0.hasPrefix("s") && $0.hasSuffix(".png") }.sorted()
    for (index, file) in frames.enumerated() {
        guard let source = CIImage(contentsOf: stage.appendingPathComponent(file)) else { fail("unreadable \(file)") }
        let r = rect(at: Double(index) / fps)
        let h = r.w * outH / outW
        // Translate first, then Lanczos: sub-pixel steps keep a slow move from shimmering, which
        // ffmpeg's zoompan cannot do — it rounds the rect to whole pixels.
        let moved = source.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -r.x, y: -(source.extent.height - r.y - h)))
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(moved, forKey: kCIInputImageKey)
        lanczos.setValue(outW / r.w, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        let image = lanczos.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
        let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)!
        let url = out.appendingPathComponent(String(format: "f%04d.png", index + 1))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    }
    print("\(frames.count) frames")
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "" {
case "check":
    // Measured on macOS 15.3: these are asked of the process that macOS holds responsible for
    // this one — for Claude Code that is the inner claude.app, not Claude.app.
    print("accessibility", AXIsProcessTrusted())
    print("screen recording", CGPreflightScreenCaptureAccess())
    print("post events", CGPreflightPostEventAccess())
case "screen":
    guard let screen = NSScreen.main else { fail("no screen") }
    print(
        screen.backingScaleFactor, Int(screen.frame.maxY - screen.visibleFrame.maxY), Int(screen.frame.width),
        Int(screen.frame.height))
case "onscreen":
    for window in windowList() where (window[kCGWindowLayer as String] as? Int) == 0 && bounds(window).width > 100 {
        print(window[kCGWindowOwnerName as String] ?? "?")
    }
case "clear-notifications":
    // A banner lands in the top right corner, inside a stage, and stays in an alert's case. Close
    // is the action its × performs (measured on macOS 15.3); Press would open the app instead.
    guard let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first
    else { fail("no Notification Center") }
    var closed = 0
    for _ in 0..<20 {
        var target: (AXUIElement, String)?
        _ = walk(AXUIElementCreateApplication(center.processIdentifier)) { element in
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            guard let close = (names as? [String])?.first(where: { $0.hasPrefix("Name:Close") }) else { return false }
            target = (element, close)
            return true
        }
        guard let (element, action) = target else { break }
        AXUIElementPerformAction(element, action as CFString)
        closed += 1
        Thread.sleep(forTimeInterval: 0.4)
    }
    print("closed \(closed)")
case "quit":
    guard args.count == 2, let pid = pid_t(args[1]), let app = NSRunningApplication(processIdentifier: pid) else {
        fail("quit <pid>: no such app")
    }
    // Not `osascript quit`: under a debugger that did nothing, and terminate() did.
    app.terminate()
case "backdrop":
    guard args.count == 5, let x = Double(args[1]), let y = Double(args[2]), let w = Double(args[3]),
        let h = Double(args[4]), let screen = NSScreen.screens.first
    else { fail("backdrop x y w h") }
    // A plain window instead of a terminal: nothing on it to black out in the edit.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let frame = NSRect(x: x, y: screen.frame.maxY - y - h, width: w, height: h)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.backgroundColor = .black
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
    app.run()
case "bar":
    for window in windowList() where (window[kCGWindowLayer as String] as? Int) == 25 {
        let r = bounds(window)
        print(Int(r.minX), Int(r.width), window[kCGWindowOwnerPID as String] ?? 0, window[kCGWindowOwnerName as String] ?? "")
    }
case "ax":
    ax(Array(args.dropFirst()))
case "activate":
    guard args.count == 2, let pid = pid_t(args[1]) else { fail("activate <pid>") }
    _ = NSRunningApplication(processIdentifier: pid)?.activate()
case "glide":
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else { fail("glide x y [click]") }
    glide(to: CGPoint(x: x, y: y), click: args.count > 3 && args[3] == "click")
case "key":
    guard args.count >= 2, let code = CGKeyCode(args[1]) else { fail("key <code> [cmd,opt,ctrl,shift]") }
    press(code, flags: args.count > 2 ? flags(args[2]) : [])
case "space":
    guard args.count == 2 else { fail("space left|right") }
    press(args[1] == "left" ? 123 : 124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
case "zoom":
    try zoom(Array(args.dropFirst()))
default:
    fail("aw-media check|screen|onscreen|bar|quit|backdrop|clear-notifications|ax|activate|glide|key|space|zoom — see the top of aw-media.swift")
}
