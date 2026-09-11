import XCTest

@testable import AgentWatchApp

/// Real files, because the whole value of this type is the one it leaves on disk for another
/// program to run. A stubbed file system would check the half that was never in doubt.
final class SenderLinkTests: XCTestCase {
    func testTheLinkPointsAtTheSenderBesideTheRunningExecutable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let build = try makeBuild(named: "debug", in: directory)

        let written = SenderLink(directoryURL: directory).refresh(forExecutableAt: build.executable)

        XCTAssertEqual(written, .stable(directory.appendingPathComponent("AgentWatchSend").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: written.path),
            build.sender.path
        )
    }

    /// Asking what the link says must not be a way of writing it.
    ///
    /// The tooling window reports what Agent Watch has put into other programs, and it
    /// rebuilds on every `present()` and after every action in it. Asking through `refresh`
    /// meant a window whose whole job is to describe the state re-created the link each time
    /// it was opened.
    func testReadingTheCurrentAnswerLeavesTheFolderUntouched() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let build = try makeBuild(named: "debug", in: directory)
        let link = SenderLink(directoryURL: directory)

        let reported = link.current(forExecutableAt: build.executable)

        XCTAssertEqual(
            reported,
            .tiedToThisBuild(build.sender.path),
            "with no link made yet, the honest answer is the build's own sender"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("AgentWatchSend").path),
            "reading made no link"
        )

        // And once the link exists, reading names it — the same answer `refresh` gives,
        // without doing the work again.
        XCTAssertEqual(
            link.refresh(forExecutableAt: build.executable),
            .stable(directory.appendingPathComponent("AgentWatchSend").path))
        XCTAssertEqual(
            link.current(forExecutableAt: build.executable),
            .stable(directory.appendingPathComponent("AgentWatchSend").path))
    }

    /// The whole reason the link exists. Codex hashes the hook entry it trusts, and the entry
    /// carries this path — so a path that moved with the build would cost a fresh approval on
    /// every switch between the installed copy and the one under development.
    func testSwitchingBuildsMovesTheLinkAndNotThePathWeWroteDown() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try makeBuild(named: "Applications", in: directory)
        let development = try makeBuild(named: "debug", in: directory)
        let link = SenderLink(directoryURL: directory)

        let first = link.refresh(forExecutableAt: installed.executable)
        let second = link.refresh(forExecutableAt: development.executable)

        XCTAssertEqual(first, second, "the path another program was told to run must never move")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: second.path),
            development.sender.path,
            "the link follows the build that is running now"
        )
    }

    /// Monitoring must fail open. If the link cannot be made, naming it anyway would write a
    /// path that runs nothing — hooks would go quiet and the widget would sit empty with no
    /// way to tell that from an idle machine. The build's own sender still works, so say that.
    func testAnUnwritableFolderFallsBackToTheSenderItself() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let build = try makeBuild(named: "debug", in: directory)
        let unwritable = directory.appendingPathComponent("nowhere", isDirectory: true)

        let written = SenderLink(directoryURL: unwritable).refresh(forExecutableAt: build.executable)

        XCTAssertEqual(
            written,
            .tiedToThisBuild(build.sender.path),
            "a path that dies with this build must not pass for the one that outlives it")
    }

    /// The name may already be taken by a real file rather than a link — an older copy, or a
    /// leftover. It sits inside Agent Watch's own folder under a name Agent Watch chose, so it
    /// is ours to replace; what must not happen is the silent alternative, where the name
    /// stays a plain file and every hook runs yesterday's build for good.
    func testAPlainFileUnderTheLinkNameIsReplacedByTheLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let build = try makeBuild(named: "debug", in: directory)
        let link = directory.appendingPathComponent("AgentWatchSend")
        try Data("an older copy".utf8).write(to: link)

        let written = SenderLink(directoryURL: directory).refresh(forExecutableAt: build.executable)

        XCTAssertEqual(written, .stable(link.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: written.path), build.sender.path)
    }

    /// The folder is Agent Watch's own and a person opens it to read the debug log, so a
    /// half-name left behind by the update would be one more thing to explain. It also guards
    /// the update itself: the way to replace a link without ever leaving the name empty is a
    /// second one under a temporary name, and this is what says it did not survive the swap.
    func testUpdatingLeavesNothingBesideTheLink() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let build = try makeBuild(named: "debug", in: directory)
        let link = SenderLink(directoryURL: directory)

        link.refresh(forExecutableAt: build.executable)
        link.refresh(forExecutableAt: build.executable)

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(left, ["AgentWatchSend", "debug"], "the update left something behind")
    }

    /// Xcode builds only the product its scheme runs, and the sender is a product of its own —
    /// so a run from Xcode has an app with no sender beside it. Pointing the link at a file
    /// that is not there would break hooks that were working, and the installed bundle's
    /// sender delivers to whichever copy holds the socket anyway. So the link stays where it
    /// is, and the app is told the path it must not overwrite.
    func testABuildWithNoSenderBesideItLeavesTheLinkAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try makeBuild(named: "Applications", in: directory)
        let senderless = directory.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: senderless, withIntermediateDirectories: true)
        try Data().write(to: senderless.appendingPathComponent("AgentWatch"))
        let link = SenderLink(directoryURL: directory)
        let established = link.refresh(forExecutableAt: installed.executable)

        let afterwards = link.refresh(forExecutableAt: senderless.appendingPathComponent("AgentWatch"))

        XCTAssertEqual(afterwards, established, "a build with no sender must not claim the link")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: established.path),
            installed.sender.path,
            "the link still names a sender that exists"
        )
    }

    /// Leaving the link alone is the right answer only when there is a link to leave. On a
    /// first run from Xcode there is neither a link nor a sender, and calling the link stable
    /// would write a name that runs nothing while claiming it outlives the build. Name the
    /// missing file instead: it is the one that says why.
    func testWithNeitherALinkNorASenderTheMissingFileIsNamed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let senderless = directory.appendingPathComponent("xcode", isDirectory: true)
        try FileManager.default.createDirectory(at: senderless, withIntermediateDirectories: true)
        let executable = senderless.appendingPathComponent("AgentWatch")
        try Data().write(to: executable)

        let written = SenderLink(directoryURL: directory).refresh(forExecutableAt: executable)

        XCTAssertEqual(written, .tiedToThisBuild(senderless.appendingPathComponent("AgentWatchSend").path))
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    /// One build's pair of files: the app and the sender sitting next to it, which is the
    /// arrangement both `build-app.sh` and `swift build` produce.
    private func makeBuild(named name: String, in directory: URL) throws -> (executable: URL, sender: URL) {
        let buildDirectory = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        let executable = buildDirectory.appendingPathComponent("AgentWatch")
        let sender = buildDirectory.appendingPathComponent("AgentWatchSend")
        try Data().write(to: executable)
        // Executable, like the real thing: a sender the link cannot run is no better than one
        // that is not there, and the rule under test says so.
        try Data().write(to: sender)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sender.path)
        return (executable, sender)
    }
}
