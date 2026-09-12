import Foundation

/// One published build of the app, as GitHub's releases API describes it.
public struct AppRelease: Equatable, Sendable {
    /// The tag without its `v`: `v0.2.0` is version `0.2.0`. The tag is what the release
    /// workflow checks against `Info.plist`, so the two cannot drift apart.
    public let version: String
    /// Where a person reads about this release. The fallback for everything the app cannot do
    /// itself — no file attached, no room to write, an install that failed.
    public let pageURL: URL
    /// The app archive, when the release carries one.
    public let downloadURL: URL?
    /// The checksum file beside it. Downloaded and compared before anything is unpacked.
    public let checksumURL: URL?

    public init(version: String, pageURL: URL, downloadURL: URL?, checksumURL: URL?) {
        self.version = version
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.checksumURL = checksumURL
    }
}

/// What a check for updates found, in the terms the interface acts on.
public enum AppUpdateDecision: Equatable, Sendable {
    /// The running copy cannot say what version it is, so nothing can be compared. This is
    /// every build started from the build directory: there is no bundle and no `Info.plist`.
    /// Silence is the only honest answer, and it keeps development free of an update box
    /// offering the version already running.
    case ownVersionUnknown
    /// Nothing published is newer.
    case upToDate
    /// Newer, but this exact version was set aside by the person.
    case skipped(AppRelease)
    /// Newer, and not set aside.
    case available(AppRelease)
}

/// Whether a newer build exists, decided over bytes somebody else fetched.
///
/// The network lives in the application layer; everything that can be got wrong — which
/// release is newest, whether it is newer than this one, whether the person asked not to be
/// told about it — is here, where a test can hold a real API answer in a string.
public enum AppUpdate {
    /// The latest release GitHub considers finished: drafts and pre-releases are not in it.
    ///
    /// That is the behaviour wanted rather than a limitation worked around. A build marked
    /// pre-release is one being tried out, and it has no business installing itself on the
    /// machine of somebody who chose a finished version.
    ///
    /// A debug build takes `AGENT_WATCH_RELEASE_URL` instead when it is set — a test points it
    /// at one release by tag (`…/releases/tags/v0.1.0`), which is the only way to exercise
    /// updating before a finished release exists. A release build ignores it.
    public static func latestReleaseURL() -> URL? {
        #if DEBUG
            let chosen = ProcessInfo.processInfo.environment["AGENT_WATCH_RELEASE_URL"]
            if let chosen, !chosen.isEmpty {
                return URL(string: chosen)
            }
        #endif
        return URL(string: "https://api.github.com/repos/glockbender/agentwatcher/releases/latest")
    }

    /// A request GitHub's API answers with the JSON `release(from:)` reads.
    ///
    /// Written once because two callers send it — the app's check and the probe that
    /// downloads a real release — and the idle timeout is a decision, not a default: a check
    /// that hangs would hold the "one check at a time" flag for as long as the system's
    /// own limit, which is a minute.
    ///
    /// `User-Agent` is set because it would otherwise be set for us: measured, `URLSession`
    /// introduces a request as `<executable>/<CFBundleVersion> CFNetwork/… Darwin/…`, and the
    /// bundle's version is the release version — the one thing this request promises not to
    /// carry. GitHub wants some name here; it gets the app's and nothing more.
    public static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AgentWatch", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// The release in an API answer, or nothing when the answer holds none.
    public static func release(from data: Data) -> AppRelease? {
        guard
            let entry = try? JSONDecoder().decode(ReleaseEntry.self, from: data),
            entry.draft != true,
            let pageURL = URL(string: entry.htmlURL)
        else {
            return nil
        }
        let version = entry.tagName.hasPrefix("v") ? String(entry.tagName.dropFirst()) : entry.tagName
        guard !version.isEmpty else {
            return nil
        }
        // The file named after the version rather than the first zip in the release: a
        // release carries the IDE plugin too, and that one is versioned on its own. Over HTTPS
        // only — the rule in code rather than in the system's transport defaults, because one
        // of these files replaces the running application.
        let assets = entry.assets ?? []
        func asset(named name: String) -> URL? {
            guard let url = assets.first(where: { $0.name == name })?.browserDownloadURL.flatMap(URL.init(string:)),
                url.scheme == "https"
            else {
                return nil
            }
            return url
        }
        return AppRelease(
            version: version,
            pageURL: pageURL,
            downloadURL: asset(named: "AgentWatch-\(version).zip"),
            checksumURL: asset(named: "AgentWatch-\(version).zip.sha256")
        )
    }

    /// What to do about the release found, given what is running and what was set aside.
    public static func decide(
        ownVersion: String?,
        release: AppRelease?,
        skippedVersion: String?
    ) -> AppUpdateDecision {
        guard let ownVersion, !ownVersion.isEmpty else {
            return .ownVersionUnknown
        }
        guard let release, ReleaseVersion.isNewer(release.version, than: ownVersion) else {
            return .upToDate
        }
        if release.version == skippedVersion {
            return .skipped(release)
        }
        return .available(release)
    }

    /// The hash out of a `shasum -a 256` line, which is the hash, two spaces and the file name.
    public static func checksum(fromChecksumFile text: String) -> String? {
        guard
            let first = text.split(separator: "\n").first,
            let hash = first.split(separator: " ").first,
            hash.count == 64,
            hash.allSatisfy({ $0.isHexDigit })
        else {
            return nil
        }
        return String(hash).lowercased()
    }

    /// The fields of GitHub's release object this reads, and none of the other seventy.
    ///
    /// Every field a release may lack is optional, so an answer missing one still reads —
    /// the one exception is the page address, without which there is nowhere to send a
    /// person when the rest goes wrong.
    private struct ReleaseEntry: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String?

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let draft: Bool?
        let htmlURL: String
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case htmlURL = "html_url"
            case assets
        }
    }
}
