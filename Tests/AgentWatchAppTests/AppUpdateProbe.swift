import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// Downloads a real release and unpacks it, to check the half of updating that no unit test
/// reaches: the network, the checksum, `ditto`, and what comes out of the archive.
///
/// Skipped unless `UPDATE_PROBE_DIR` names a directory, because it talks to GitHub and the
/// ordinary run must not. Nothing is installed — the bundle is left in that directory.
///
///     UPDATE_PROBE_DIR=/tmp/update swift test --filter AppUpdateProbe
final class AppUpdateProbe: XCTestCase {
    func testFetchAndUnpackTheLatestRelease() async throws {
        let requested = ProcessInfo.processInfo.environment["UPDATE_PROBE_DIR"]
        try XCTSkipIf(requested == nil, "a network probe, not a check: set UPDATE_PROBE_DIR")
        let directory = URL(fileURLWithPath: try XCTUnwrap(requested), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var request = URLRequest(url: try XCTUnwrap(AppUpdate.latestReleaseURL()))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let newest = try XCTUnwrap(
            AppUpdate.release(from: data),
            "no finished release yet — everything published so far is marked pre-release"
        )
        print("latest release: \(newest.version) — \(newest.downloadURL?.absoluteString ?? "no file")")

        let staged = await AppUpdater.stage(
            downloadURL: try XCTUnwrap(newest.downloadURL),
            checksumURL: try XCTUnwrap(newest.checksumURL),
            expectedVersion: newest.version,
            beside: directory.appendingPathComponent("AgentWatch.app")
        )

        let bundle: URL = try XCTUnwrap(staged, "the release did not arrive whole, or did not unpack")
        print("unpacked: \(bundle.path)")
        let executables = bundle.appendingPathComponent("Contents/MacOS")
        XCTAssertTrue(FileManager.default.fileExists(atPath: executables.appendingPathComponent("AgentWatch").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: executables.appendingPathComponent("AgentWatchSend").path))

        // The other half of installing: putting the new bundle where the old one is. Done
        // here over a copy, because the real target is the running application.
        let target = directory.appendingPathComponent("Target.app")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: bundle, to: target)
        let staged2 = await AppUpdater.stage(
            downloadURL: try XCTUnwrap(newest.downloadURL),
            checksumURL: try XCTUnwrap(newest.checksumURL),
            expectedVersion: newest.version,
            beside: target
        )
        try FileManager.default.replaceItem(
            at: target,
            withItemAt: try XCTUnwrap(staged2),
            backupItemName: nil,
            options: [],
            resultingItemURL: nil
        )

        let installed = try XCTUnwrap(
            NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
        )
        XCTAssertEqual(installed["CFBundleShortVersionString"] as? String, newest.version)
        print("replaced in place: \(target.path) is now \(newest.version)")
    }
}
