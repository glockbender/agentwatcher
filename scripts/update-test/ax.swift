// ax windows <pid> | ax text <pid> | ax press <pid> <button title>
// Reads and presses an app's windows through Accessibility, for the update test in the machine.
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

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

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let pid = pid_t(args[1]) else { fail("ax windows|text|press <pid> [title]") }
let app = AXUIElementCreateApplication(pid)
let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []

switch args[0] {
case "windows":
    for window in windows {
        print((attribute(window, kAXTitleAttribute) as? String) ?? "")
    }
case "text":
    for window in windows {
        print("== \((attribute(window, kAXTitleAttribute) as? String) ?? "")")
        _ = walk(window) { element in
            for name in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                if let text = attribute(element, name) as? String, !text.isEmpty {
                    print(text)
                }
            }
            return false
        }
    }
case "press":
    guard args.count == 3 else { fail("ax press <pid> <title>") }
    var found: AXUIElement?
    _ = walk(app) { element in
        guard (attribute(element, kAXRoleAttribute) as? String) == kAXButtonRole,
            (attribute(element, kAXTitleAttribute) as? String) == args[2]
        else { return false }
        found = element
        return true
    }
    guard let button = found else { fail("no button: \(args[2])") }
    let enabled = (attribute(button, kAXEnabledAttribute) as? Bool) ?? true
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard result == .success else { fail("press failed: AXError \(result.rawValue), enabled=\(enabled)") }
default:
    fail("unknown command \(args[0])")
}
