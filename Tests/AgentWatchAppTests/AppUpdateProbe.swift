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

        let newest = try await anyPublishedRelease()
        print("release under test: \(newest.version) — \(newest.downloadURL?.absoluteString ?? "no file")")

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
        // here over two copies of what was just unpacked — the real target is the running
        // application, and one download is enough.
        let target = directory.appendingPathComponent("Target.app")
        let replacement = directory.appendingPathComponent("Replacement.app")
        for copy in [target, replacement] {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: bundle, to: copy)
        }
        try FileManager.default.replaceItem(
            at: target,
            withItemAt: replacement,
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

    /// The release this probe downloads: the latest finished one, or the newest of any kind.
    ///
    /// The app only ever offers a finished release. This probe checks the downloading rather
    /// than the choosing, and it must keep working while a project publishes nothing but
    /// pre-releases — otherwise the one path no unit test covers is covered by nothing at all.
    private func anyPublishedRelease() async throws -> AppRelease {
        if let finished = try await release(at: try XCTUnwrap(AppUpdate.latestReleaseURL())) {
            return finished
        }
        let list = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/glockbender/agentwatcher/releases")
        )
        let (data, _) = try await URLSession.shared.data(for: AppUpdate.request(for: list))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        let first = try XCTUnwrap(entries.first, "the repository has published nothing")
        print("no finished release yet — falling back to the newest pre-release")
        return try XCTUnwrap(AppUpdate.release(from: JSONSerialization.data(withJSONObject: first)))
    }

    private func release(at url: URL) async throws -> AppRelease? {
        let (data, response) = try await URLSession.shared.data(for: AppUpdate.request(for: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return AppUpdate.release(from: data)
    }
}
