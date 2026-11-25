import Foundation
import XCTest

@testable import AgentWatchCore

/// The app writes these names and the hook sender looks for them, from a different target,
/// with nothing between them but agreement. So the agreement is the thing under test.
final class AgentWatchPathsTests: XCTestCase {
    private let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")

    func testTheAppAndTheSenderMeetAtOneName() {
        let directory = AgentWatchPaths.supportDirectory(inApplicationSupport: support)

        XCTAssertEqual(directory.lastPathComponent, "AgentWatch")
        XCTAssertEqual(AgentWatchPaths.socketURL(inDirectory: directory).lastPathComponent, "agent-watch.sock")
        XCTAssertEqual(
            AgentWatchPaths.socketURL(inDirectory: directory).deletingLastPathComponent(),
            directory,
            "the socket sits in the app's own folder, beside the lock that keeps it single"
        )
    }
    func testDevelopmentSocketAndDirectoryAreSeparate() {
        let production = AgentWatchPaths.supportDirectory(inApplicationSupport: support, development: false)
        let development = AgentWatchPaths.supportDirectory(inApplicationSupport: support, development: true)
        XCTAssertEqual(development.lastPathComponent, "AgentWatch Dev")
        XCTAssertNotEqual(
            AgentWatchPaths.socketURL(inDirectory: development), AgentWatchPaths.socketURL(inDirectory: production))
    }

    func testSenderIdentifiesItsHostBundleThroughAStableLink() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for development in [true, false] {
            let name = development ? "Dev" : "Production"
            let identifier = development ? AgentWatchPaths.developmentBundleIdentifier : "com.glockbender.agentwatch"
            let contents = root.appendingPathComponent("\(name).app/Contents")
            let bin = contents.appendingPathComponent("MacOS")
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            let info = [
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "AgentWatch", "CFBundlePackageType": "APPL",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let executable = bin.appendingPathComponent("AgentWatchSend")
            try Data().write(to: executable)
            let link = root.appendingPathComponent("sender-\(name)")
            try files.createSymbolicLink(at: link, withDestinationURL: executable)
            XCTAssertEqual(
                AgentWatchPaths.identifiesDevelopmentBuild(bundleIdentifier: nil, executable: link), development)
        }
    }

}
