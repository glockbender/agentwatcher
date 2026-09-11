import AgentWatchCore
import XCTest

@testable import AgentWatchApp

/// Real files, because the whole point is a fact that outlives the process. Kept out of
/// `UserDefaults` for a reason measured earlier: the defaults domain depends on how the app
/// was launched — one name inside the bundle, another under `swift run` — so a memory kept
/// there would reset every time a person switched between an installed copy and their own
/// build, and the app would announce a broken installation that works.
@MainActor
final class AgentHeardStoreTests: XCTestCase {
    func testWhatWasHeardOnceIsStillKnownAfterARestart() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AgentHeardStore(directoryURL: directory)
        XCTAssertNotEqual(store.delivery(for: .codex), .arrived)

        store.record(.codex, at: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(store.delivery(for: .codex), .arrived)
        XCTAssertNotEqual(
            store.delivery(for: .claude), .arrived, "one agent reporting says nothing about the other")
        XCTAssertEqual(
            AgentHeardStore(directoryURL: directory).delivery(for: .codex),
            .arrived,
            "a fact about whether an installation ever worked cannot start over with the app"
        )
    }

    /// The three answers, and the middle one is the only claim the app is entitled to make.
    ///
    /// Records it did not install are none of its business: they may have worked for months
    /// before it started keeping track, and calling their silence a fault would announce a
    /// problem on the first launch of every working setup. Records it installed itself and has
    /// heard nothing from are a different matter — for Codex that is the usual state until a
    /// person approves them there.
    func testSilenceIsOnlyClaimedAboutRecordsThisAppInstalled() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentHeardStore(directoryURL: directory)

        XCTAssertEqual(store.delivery(for: .codex), .unknown)

        store.recordInstall(.codex)
        XCTAssertEqual(store.delivery(for: .codex), .nothingSinceInstall)
        XCTAssertEqual(store.delivery(for: .claude), .unknown, "and it is per agent")

        store.record(.codex, at: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(store.delivery(for: .codex), .arrived)

        XCTAssertEqual(
            AgentHeardStore(directoryURL: directory).delivery(for: .codex),
            .arrived,
            "both halves outlive the process, or the answer changes on every restart"
        )
    }

    /// Taking the hooks away takes the claim with it. Records a person puts back by hand are
    /// not ours, and saying "we installed these and they are silent" about them would be a
    /// statement about somebody else's work.
    func testRemovingTheHooksGivesUpTheClaim() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentHeardStore(directoryURL: directory)

        store.recordInstall(.claude)
        store.forgetInstall(.claude)

        XCTAssertEqual(store.delivery(for: .claude), .unknown)
        XCTAssertEqual(AgentHeardStore(directoryURL: directory).delivery(for: .claude), .unknown)
    }

    /// Events arrive several times a minute, and the fact this file exists for is settled by
    /// its first write. So a second event inside the window leaves the file alone rather than
    /// rewriting it for a date nothing reads yet.
    func testASecondEventInTheSameMinuteDoesNotRewriteTheFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentHeardStore(directoryURL: directory)
        let first = Date(timeIntervalSince1970: 1_000)

        store.record(.claude, at: first)
        let afterFirst = try Self.storedMoment(of: .claude, in: directory)
        store.record(.claude, at: first + 5)

        XCTAssertEqual(try Self.storedMoment(of: .claude, in: directory), afterFirst)

        store.record(.claude, at: first + 120)

        XCTAssertEqual(try Self.storedMoment(of: .claude, in: directory), first.timeIntervalSince1970 + 120)
    }

    /// Fail open, like every other read of a file this app did not just write. A file somebody
    /// edited, or one a full disk truncated, must not stop the app — it costs one sentence in
    /// a menu, and the price of throwing here would be the whole launch.
    func testAFileThatCannotBeUnderstoodReadsAsHavingHeardNothing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("agents-heard.json"))

        let store = AgentHeardStore(directoryURL: directory)

        XCTAssertEqual(store.delivery(for: .claude), .unknown)
        store.record(.claude, at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(store.delivery(for: .claude), .arrived, "and the ruined file is replaced by a usable one")
        XCTAssertEqual(AgentHeardStore(directoryURL: directory).delivery(for: .claude), .arrived)
    }

    /// Read out of the file rather than off the object, because what is under test is whether
    /// the file was rewritten.
    private static func storedMoment(of source: AgentSource, in directory: URL) throws -> Double? {
        let data = try Data(contentsOf: directory.appendingPathComponent("agents-heard.json"))
        return try JSONDecoder().decode(StoredMoments.self, from: data).heard[source.rawValue]
    }

    private struct StoredMoments: Decodable {
        let heard: [String: Double]
    }

    private func makeDirectory() throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }
}
