import CoreGraphics
import Foundation

// Read window numbers without inspecting titles or acting on the confirmation.
guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("Cannot read the WindowServer list\n".utf8))
    exit(1)
}
let owners = Set(CommandLine.arguments.dropFirst().compactMap(Int.init))
let modalLevel = Int(CGWindowLevelForKey(.modalPanelWindow))
for row in rows {
    if let owner = row[kCGWindowOwnerPID as String] as? Int, owners.contains(owner),
        let level = row[kCGWindowLayer as String] as? Int, level == modalLevel || level == 0,
        let number = row[kCGWindowNumber as String] as? Int
    {
        print(number)
    }
}
