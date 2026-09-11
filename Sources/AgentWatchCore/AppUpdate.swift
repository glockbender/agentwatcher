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
    /// Not `/releases/latest`, and that is measured rather than preferred: `/latest` skips
    /// anything marked pre-release, and this project's releases are marked exactly that while
    /// it is an alpha. The address answered 404 for the only release that exists. The list
    /// endpoint answers with everything, newest first, and the choice is made here.
    public static func releasesURL() -> URL? {
        URL(string: "https://api.github.com/repos/glockbender/agentwatcher/releases")
    }

    /// The releases in an API answer, drafts left out.
    ///
    /// A draft is a release nobody has published yet. It needs a token to be visible at all,
    /// so this rarely has anything to do — but a draft is exactly the release whose files are
    /// half uploaded, and offering one to a person would be offering a broken download.
    public static func releases(from data: Data) -> [AppRelease] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return parsed.compactMap(release(from:))
    }

    /// What to do about the releases found, given what is running and what was set aside.
    public static func decide(
        ownVersion: String?,
        releases: [AppRelease],
        skippedVersion: String?
    ) -> AppUpdateDecision {
        guard let ownVersion, !ownVersion.isEmpty else {
            return .ownVersionUnknown
        }
        // The newest by version rather than the first in the list: the order GitHub returns is
        // by creation time, and a release created later can carry an earlier version — a fix
        // published for an older line, or a tag pushed twice.
        guard
            let newest = releases.max(by: { ReleaseVersion.isNewer($1.version, than: $0.version) }),
            ReleaseVersion.isNewer(newest.version, than: ownVersion)
        else {
            return .upToDate
        }
        if newest.version == skippedVersion {
            return .skipped(newest)
        }
        return .available(newest)
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
