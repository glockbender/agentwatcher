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
//   ax findm <pid> <text>         as find, inside a menu only
//   ax findw <pid> <title|-> <text>   as find, inside the window whose title ends with <title>
//   ax press <pid> <text>         press the first element whose identifier or title is <text>
//   ax dismiss <pid> [keep …]     press every row's "×" except on rows whose text holds a kept name
//   ax windows <pid>              frame and title of every window
//   ax close <pid> <title>        press the close button of the window whose title ends with it
//   ax move <pid> <title|-> x y w h   set a window's frame; "-" is the untitled one (the widget)
//   ax fullscreen <pid> <title|-> on|off   enter or leave the window's own full-screen space
//   activate <pid>                bring an app forward
//   glide x y [click]             move the pointer along an eased path, then click if asked and
//                                 print the wall time of the press
//   drag x y x2 y2 [seconds]      glide to x y, press, move to x2 y2 along an eased path (0.8 s),
//                                 release; prints the wall time of the press
//   scroll <points> [seconds] [back]  scroll where the pointer is, at an even speed; positive goes
//                                 down a list; `back` returns at once, with no stop between
//   key <code> [cmd,opt,ctrl,shift]  press and release one key (53 is Escape, 13 is W)
//   space left|right              Control-arrow: the next desktop
//   zoom <stage dir> <keys> <out dir> <width> <height> <fps> [taps]
//                                 render s0001.png… through moving crop rects into f0001.png…,
//                                 with a ring at each press in <taps>, "t x y" a line
//   record <out.mov> <t0 file>    the main screen at its own pixels, 30 frames a second, until
//                                 SIGINT; the wall time of the first frame goes to <t0 file>
//   display <width> <height>      switch the main screen to that size in points at 2x, for good
//   type <text> [seconds a key]   type into whatever has the focus, key by key (U.S. layout)
//   wallpaper <image>             the desktop picture of every screen
import AVFoundation
import AppKit
import ApplicationServices
import CoreImage
import ImageIO
import ScreenCaptureKit
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

func inMenu(_ element: AXUIElement) -> Bool {
    var current: AnyObject? = element
    while let e = current {
        let element = e as! AXUIElement
        if attribute(element, kAXRoleAttribute) as? String == kAXMenuRole { return true }
        current = attribute(element, kAXParentAttribute)
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
    // A window by the end of its title; "-" is the untitled one (the widget).
    func window(_ title: String) -> AXUIElement {
        let want = title == "-" ? "" : title
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard
            let window = windows.first(where: {
                let title = (attribute($0, kAXTitleAttribute) as? String) ?? ""
                return want.isEmpty ? title.isEmpty : title.hasSuffix(want)
            })
        else { fail("no window: \(title)") }
        return window
    }
    switch args[0] {
    case "find", "findc", "findm":
        guard args.count == 3 else { fail("ax find <pid> <text>") }
        var hit: CGRect?
        _ = walk(app) { element in
            let t = text(element)
            guard args[0] == "findc" ? t.contains(args[2]) : t.hasSuffix(args[2]), let f = frame(element) else {
                return false
            }
            // A session's row is in the widget as well as in the menu, and the widget comes first.
            if args[0] == "findm" && !inMenu(element) { return false }
            hit = f
            return true
        }
        guard let f = hit else { fail("none: \(args[2])") }
        print(Int(f.midX), Int(f.midY), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
    case "findw":
        // A closed menu keeps its items, with frames at the screen's bottom left: "Closed" found one.
        guard args.count == 4 else { fail("ax findw <pid> <title|-> <text>") }
        var hit: CGRect?
        _ = walk(window(args[2])) { element in
            guard text(element).hasSuffix(args[3]), let f = frame(element) else { return false }
            hit = f
            return true
        }
        guard let f = hit else { fail("none in \(args[2]): \(args[3])") }
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
        let target = window(args[2])
        var size = CGSize(width: w, height: h)
        var point = CGPoint(x: x, y: y)
        // The place first: a size that does not fit on the screen from where the window stands is cut
        // to fit, measured on macOS 15.7.7 on a 1152-point screen. Placed again after, in case the
        // new size moved it.
        AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
        AXUIElementSetAttributeValue(target, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        AXUIElementSetAttributeValue(target, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
    case "fullscreen":
        guard args.count == 4, ["on", "off"].contains(args[3]) else { fail("ax fullscreen <pid> <title|-> on|off") }
        // The window's green button does the same; a key would depend on the focus and the app's bindings.
        let done = AXUIElementSetAttributeValue(
            window(args[2]), "AXFullScreen" as CFString, (args[3] == "on") as CFBoolean)
        guard done == .success else { fail("AXFullScreen refused: \(done.rawValue)") }
    default:
        fail("ax: unknown \(args[0])")
    }
}

// MARK: - Input

func post(_ type: CGEventType, _ at: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)!.post(tap: .cghidEventTap)
}

/// An eased path: a jump straight to the target can miss a hover state the click depends on.
// Every pause in a virtual machine lasted at least about 50 ms, whatever was asked: 45 steps of
// 14 ms took 2.8 s instead of 0.63 (measured on macOS 15.7.7 under Tart 2.40.1). So motion and
// typing follow the clock, and a late pause shortens the next one instead of adding up.
func pause(until deadline: Date) {
    let wait = deadline.timeIntervalSinceNow
    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
}

func glide(to target: CGPoint, click: Bool) {
    let start = CGEvent(source: nil)!.location
    let began = Date()
    let duration = 0.63
    var t = 0.0
    while t < 1 {
        t = min(1, Date().timeIntervalSince(began) / duration)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        post(.mouseMoved, CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e))
        usleep(14_000)
    }
    guard click else { return }
    usleep(250_000)
    post(.leftMouseDown, target)
    let pressed = Date().timeIntervalSince1970
    usleep(90_000)
    post(.leftMouseUp, target)
    print(String(format: "%.3f", pressed))
}

/// A press, a move with the button held, a release: a slider's knob, a widget's edge, a row
/// dragged into place. The pauses at both ends let the control see a press before the move and
/// the last position before the release.
func drag(from start: CGPoint, to end: CGPoint, seconds: Double) {
    glide(to: start, click: false)
    usleep(250_000)
    post(.leftMouseDown, start)
    let pressed = Date().timeIntervalSince1970
    usleep(200_000)
    let began = Date()
    var t = 0.0
    while t < 1 {
        t = min(1, Date().timeIntervalSince(began) / seconds)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e))
        usleep(14_000)
    }
    usleep(200_000)
    post(.leftMouseUp, end)
    print(String(format: "%.3f", pressed))
}

/// Pixel deltas in small steps by the clock, as a trackpad sends them, so the list glides on camera.
/// At an even speed: an eased scroll slowed down at its ends, the pointer stayed on one row of the
/// widget past the half second that opens the row's card, and the card covered the scrolling. And
/// with a move of half a point every step: under a pointer that stood still, a row that scrolled
/// away was never left, and the first row to pass opened its card.
func scroll(points: Double, seconds: Double) {
    let start = CGEvent(source: nil)!.location
    let began = Date()
    var done = 0.0
    var t = 0.0
    var nudge = 0.5
    while t < 1 {
        t = min(1, Date().timeIntervalSince(began) / seconds)
        let step = (points * t - done).rounded()
        if step != 0 {
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-step), wheel2: 0, wheel3: 0)!
                .post(tap: .cghidEventTap)
            done += step
        }
        post(.mouseMoved, CGPoint(x: start.x, y: start.y + nudge))
        nudge = -nudge
        usleep(14_000)
    }
    post(.mouseMoved, start)
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

/// Key codes of the U.S. layout, the virtual machine's, for every character a take types; `true`
/// holds Shift. Keys rather than a pasted string, because a terminal shows a paste at once and a
/// TUI may take it for one.
let usKeys: [Character: (CGKeyCode, Bool)] = {
    var keys: [Character: (CGKeyCode, Bool)] = [:]
    let plain: [(String, CGKeyCode)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
        ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
        ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
        ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
        (" ", 49), ("`", 50),
    ]
    let shifted: [(String, CGKeyCode)] = [
        ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("%", 23), ("^", 22), ("&", 26), ("*", 28), ("(", 25),
        (")", 29), ("_", 27), ("+", 24), ("{", 33), ("}", 30), ("|", 42), (":", 41), ("\"", 39), ("<", 43),
        (">", 47), ("?", 44), ("~", 50),
    ]
    for (character, code) in plain {
        keys[Character(character)] = (code, false)
        if character.first!.isLetter { keys[Character(character.uppercased())] = (code, true) }
    }
    for (character, code) in shifted { keys[Character(character)] = (code, true) }
    return keys
}()

/// Types at about `interval` seconds a key, unevenly, as a person does.
func type(_ text: String, interval: Double) {
    var next = Date()
    for (index, character) in text.enumerated() {
        guard let (code, shift) = usKeys[character] else { fail("no U.S. key for \(character)") }
        pause(until: next)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = shift ? .maskShift : []
            event.post(tap: .cghidEventTap)
        }
        let jitter = 0.6 + 0.8 * abs(sin(Double(index) * 12.9898)).truncatingRemainder(dividingBy: 1)
        next += interval * jitter
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

/// A press, in clip seconds and stage pixels.
struct Tap {
    let t, x, y: Double
}

/// How long a press's ring lasts.
let ringSeconds = 0.5

/// A press as a ring that grows and fades, sized for a 2x recording: from 14 to 24 points, a
/// translucent dark disc with a white edge, which reads on a dark terminal and a light window alike.
func ring(_ progress: Double) -> CIImage {
    let eased = 1 - pow(1 - progress, 2)
    let radius = 28 + 20 * eased
    let fade = 1 - progress
    let side = 104
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let disc = CGRect(x: Double(side) / 2 - radius, y: Double(side) / 2 - radius, width: 2 * radius, height: 2 * radius)
    context.setFillColor(CGColor(gray: 0, alpha: 0.3 * fade))
    context.fillEllipse(in: disc)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.9 * fade))
    context.setLineWidth(3)
    context.strokeEllipse(in: disc.insetBy(dx: 1.5, dy: 1.5))
    return CIImage(cgImage: context.makeImage()!)
}

/// Keyframes are "t x y w" in stage pixels from the top left; a pair with the same rect is a
/// hold, and between two different ones the rect moves with smoothstep easing.
func zoom(_ args: [String]) throws {
    guard args.count == 6 || args.count == 7, let outW = Double(args[3]), let outH = Double(args[4]),
        let fps = Double(args[5])
    else {
        fail("zoom <stage dir> <keys> <out dir> <width> <height> <fps> [taps]")
    }
    let taps: [Tap] =
        args.count < 7
        ? []
        : try String(contentsOfFile: args[6], encoding: .utf8).split(separator: "\n").compactMap { line in
            let v = line.split(separator: " ").compactMap { Double($0) }
            return v.count == 3 ? Tap(t: v[0], x: v[1], y: v[2]) : nil
        }
    let lines: [Substring] = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n")
    let numbers: [[Double]] = lines.map { line in
        let code: Substring = line.split(separator: "#", omittingEmptySubsequences: false)[0]
        return code.split(separator: " ").compactMap { Double($0) }
    }
    let keys: [Key] = numbers
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
        guard var source = CIImage(contentsOf: stage.appendingPathComponent(file)) else { fail("unreadable \(file)") }
        let t = Double(index) / fps
        // Drawn on the stage, before the crop: a ring grows with the zoom, as the pointer does. Cut
        // back to the stage, or a ring at its edge would move what the crop below measures from.
        let extent = source.extent
        for tap in taps where t >= tap.t && t < tap.t + ringSeconds {
            let mark = ring((t - tap.t) / ringSeconds)
            let half = mark.extent.width / 2
            source = mark.transformed(by: CGAffineTransform(translationX: tap.x - half, y: extent.height - tap.y - half))
                .composited(over: source).cropped(to: extent)
        }
        let r = rect(at: t)
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
        let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)!
        // Drawn again without alpha: ImageIO wrote some frames as RGB and some as RGBA, and ffmpeg
        // rebuilds its filters at every such change, which dropped the start of a contact sheet.
        let opaque = CGContext(
            data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        opaque.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        let cg = opaque.makeImage()!
        let url = out.appendingPathComponent(String(format: "f%04d.png", index + 1))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
    }
    print("\(frames.count) frames")
}

// MARK: - Recording

/// ScreenCaptureKit, not ffmpeg's avfoundation input: in a virtual machine, which has no hardware
/// encoder, that input delivered about 22 frames a second at any size and a stream 57, and of the
/// software encoders only ProRes kept 30 frames a second at 3456×2234, measured on macOS 15.7.7.
/// H.264 dropped some frames there and HEVC half.
final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let t0File: URL
    var started = false
    var dropped = 0
    var last: CMSampleBuffer?

    init(out: URL, t0File: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: out)
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        self.t0File = t0File
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // A still screen sends idle frames with no picture; the movie simply holds the last one.
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
            let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete
        else { return }
        let time = buffer.presentationTimeStamp
        if !started {
            guard writer.startWriting() else { fail("cannot write: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: time)
            // The frame was taken before it arrived: its wall time is now less its age.
            let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), time))
            try? String(format: "%.6f", Date().timeIntervalSince1970 - age).write(to: t0File, atomically: true, encoding: .utf8)
            started = true
        }
        if input.isReadyForMoreMediaData && input.append(buffer) { last = buffer } else { dropped += 1 }
    }

    /// A still screen sends no frames, so a movie ended at the screen's last change rather than at
    /// the stop: the setup take lost the three seconds that hold its last picture. That picture is
    /// written again at the moment of the stop.
    func holdLastFrame() {
        guard let last else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
            == noErr, let copy
        else { return }
        for _ in 0..<100 where !input.isReadyForMoreMediaData { usleep(10_000) }
        if !input.append(copy) { dropped += 1 }
    }
}

/// What the recording's callbacks need alive once `record` has handed the thread to `dispatchMain`.
nonisolated(unsafe) var recording: [AnyObject] = []

func record(_ args: [String]) -> Never {
    guard args.count == 2, let screen = NSScreen.main else { fail("record <out.mov> <t0 file>") }
    let scale = Int(screen.backingScaleFactor)
    // A movie stopped without finishing has no index and cannot be read: SIGINT finishes it.
    signal(SIGINT, SIG_IGN)
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            fail("no display to record: \(String(describing: error))")
        }
        let config = SCStreamConfiguration()
        config.width = display.width * scale
        config.height = display.height * scale
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // No showMouseClicks: it drew nothing for the takes' posted clicks, measured on macOS
        // 15.7.7 in the virtual machine, and the cut draws a ring of its own (zoom's taps).
        config.showsCursor = true
        config.queueDepth = 8
        do {
            let recorder = try Recorder(
                out: URL(fileURLWithPath: args[0]), t0File: URL(fileURLWithPath: args[1]), width: config.width,
                height: config.height)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            let frames = DispatchQueue(label: "frames")
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: frames)
            let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            stop.setEventHandler {
                stream.stopCapture { _ in
                    frames.sync { recorder.holdLastFrame() }
                    recorder.input.markAsFinished()
                    recorder.writer.finishWriting {
                        if recorder.dropped > 0 { FileHandle.standardError.write("dropped \(recorder.dropped) frames\n".data(using: .utf8)!) }
                        exit(recorder.writer.status == .completed ? 0 : 1)
                    }
                }
            }
            stop.resume()
            recording = [stream, recorder, stop]
            stream.startCapture { error in
                if let error { fail("cannot record: \(error)") }
            }
        } catch { fail("cannot record \(args[0]): \(error)") }
    }
    dispatchMain()
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
case "drag":
    guard args.count >= 5, let x = Double(args[1]), let y = Double(args[2]), let x2 = Double(args[3]),
        let y2 = Double(args[4])
    else { fail("drag x y x2 y2 [seconds]") }
    drag(from: CGPoint(x: x, y: y), to: CGPoint(x: x2, y: y2), seconds: args.count > 5 ? Double(args[5]) ?? 0.8 : 0.8)
case "scroll":
    guard args.count >= 2, let points = Double(args[1]) else { fail("scroll <points> [seconds] [back]") }
    let seconds = args.count > 2 ? Double(args[2]) ?? 0.8 : 0.8
    scroll(points: points, seconds: seconds)
    // In one process: starting another took long enough in the virtual machine for a row's card to open.
    if args.count > 3 && args[3] == "back" { scroll(points: -points, seconds: seconds) }
case "key":
    guard args.count >= 2, let code = CGKeyCode(args[1]) else { fail("key <code> [cmd,opt,ctrl,shift]") }
    press(code, flags: args.count > 2 ? flags(args[2]) : [])
case "space":
    guard args.count == 2 else { fail("space left|right") }
    press(args[1] == "left" ? 123 : 124, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
case "zoom":
    try zoom(Array(args.dropFirst()))
case "record":
    record(Array(args.dropFirst()))
case "type":
    guard args.count >= 2 else { fail("type <text> [seconds a key]") }
    type(args[1], interval: args.count > 2 ? Double(args[2]) ?? 0.07 : 0.07)
case "display":
    // Tart's --display sets the virtual screen, but a guest stayed at the 1024×768 at 2x it chose
    // before, whatever was asked, measured on macOS 15.7.7 under Tart 2.40.1.
    guard args.count == 3, let width = Int(args[1]), let height = Int(args[2]) else { fail("display <width> <height>") }
    let display = CGMainDisplayID()
    let all = CGDisplayCopyAllDisplayModes(display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
    let modes = all as? [CGDisplayMode] ?? []
    guard let mode = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == 2 * width }) else {
        fail("no \(width)×\(height) at 2x; the virtual screen must be at least \(2 * width)×\(2 * height) pixels")
    }
    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
    guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { fail("the screen refused \(width)×\(height)") }
    print(width, height)
case "wallpaper":
    // Through NSWorkspace: an AppleScript to System Events would first ask a person for permission.
    guard args.count == 2 else { fail("wallpaper <image>") }
    for screen in NSScreen.screens {
        do {
            try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: args[1]), for: screen, options: [:])
        } catch {
            fail("wallpaper: \(error.localizedDescription)")
        }
    }
default:
    fail("aw-media check|screen|onscreen|bar|quit|backdrop|clear-notifications|ax|activate|glide|drag|scroll|key|space|zoom|record|display|type|wallpaper — see the top of aw-media.swift")
}
