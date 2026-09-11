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
    public static func latestReleaseURL() -> URL? {
        URL(string: "https://api.github.com/repos/glockbender/agentwatcher/releases/latest")
    }

    /// The release in an API answer, or nothing when the answer holds none.
    public static func release(from data: Data) -> AppRelease? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return release(from: parsed)
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

    private static func release(from entry: [String: Any]) -> AppRelease? {
        guard
            (entry["draft"] as? Bool) != true,
            let tag = entry["tag_name"] as? String,
            let pageAddress = entry["html_url"] as? String,
            let pageURL = URL(string: pageAddress)
        else {
            return nil
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else {
            return nil
        }
        let assets = (entry["assets"] as? [[String: Any]]) ?? []
        return AppRelease(
            version: version,
            pageURL: pageURL,
            downloadURL: assetURL(in: assets, named: "AgentWatch-\(version).zip"),
            checksumURL: assetURL(in: assets, named: "AgentWatch-\(version).zip.sha256")
        )
    }

    /// The file named after the version rather than the first zip in the release: a release
    /// carries the IDE plugin too, and that one is versioned on its own.
    private static func assetURL(in assets: [[String: Any]], named name: String) -> URL? {
        for asset in assets where (asset["name"] as? String) == name {
            if let address = asset["browser_download_url"] as? String {
                return URL(string: address)
            }
        }
        return nil
    }
}
