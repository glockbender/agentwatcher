import AgentWatchCore
import AppKit
import CryptoKit

/// Finding out that a newer build exists, and putting it in place.
///
/// This is the one thing Agent Watch does that reaches outside the machine. The request is a
/// plain `GET` to GitHub's public API with nothing of the person's in it — no identifier, no
/// query, not even which version is running, because the comparison happens here. GitHub sees
/// what any web server sees: an address and an IP. It can be turned off, and it turns itself
/// off in a build that has no version to compare.
///
/// The update is downloaded by the app rather than by a browser, and that is worth a sentence
/// because it changes what the person has to do: `com.apple.quarantine` is written by whoever
/// downloads a file, and a browser writes it. A build fetched here carries no such flag, so it
/// opens without the ceremony the first install needs. Measured on a real release.
@MainActor
final class AppUpdater: PreferenceDefaults {
    private enum Key {
        static let checksOnLaunch = "checkForUpdatesOnLaunch"
        static let skippedVersion = "skippedUpdateVersion"
    }

    /// How long after launch the check happens. Late enough that it competes with nothing a
    /// person is waiting for, early enough to be the same session they opened the app in.
    private static let delayAfterLaunch: Duration = .seconds(5)

    private let preferences: PreferenceFile
    /// One check at a time. Both the launch check and the menu item land here, and a second
    /// request while the first is in flight buys nothing but a second dialog.
    private var isWorking = false

    /// The version of the running copy, or nothing when there is no bundle to ask.
    ///
    /// `swift run` produces a bare executable with no `Info.plist`, and an update box in
    /// development offering the version already running is worse than no check at all.
    let ownVersion: String?

    init(preferences: PreferenceFile) {
        self.preferences = preferences
        let bundleURL = Bundle.main.bundleURL
        ownVersion = bundleURL.pathExtension == "app" ? Self.version(ofBundleAt: bundleURL) : nil
    }

    nonisolated var defaultValues: [String: JSONValue] {
        [
            Key.checksOnLaunch: .bool(true),
            Key.skippedVersion: .string(""),
        ]
    }

    var checksOnLaunch: Bool {
        get { preferences.flag(forKey: Key.checksOnLaunch) ?? true }
        set { preferences.set(newValue, forKey: Key.checksOnLaunch) }
    }

    /// The check that happens by itself, if the person left it on.
    func checkAfterLaunch() {
        guard checksOnLaunch, ownVersion != nil else {
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.delayAfterLaunch)
            self?.check(announceEveryOutcome: false)
        }
    }

    /// The check a person asked for, which answers even when there is nothing to say.
    func checkNow() {
        check(announceEveryOutcome: true)
    }

    private func check(announceEveryOutcome: Bool) {
        guard !isWorking else {
            return
        }
        isWorking = true
        let ownVersion = ownVersion
        let skipped = preferences.string(forKey: Key.skippedVersion)
        Task { [weak self] in
            let outcome = await Self.fetchDecision(ownVersion: ownVersion, skippedVersion: skipped)
            guard let self else {
                return
            }
            isWorking = false
            present(outcome, announceEveryOutcome: announceEveryOutcome)
        }
    }

    // MARK: - Talking to GitHub

    /// What the release list says, or `nil` when the question could not be asked at all.
    ///
    /// Every failure is one answer: no network, GitHub down, the hourly limit for an address
    /// without a token spent, an answer that is not the JSON expected. None of them is the
    /// person's problem, and none of them may interrupt what they are doing — the same
    /// fail-open rule the hooks live by.
    private nonisolated static func fetchDecision(
        ownVersion: String?,
        skippedVersion: String?
    ) async -> AppUpdateDecision? {
        guard
            let latestReleaseURL = AppUpdate.latestReleaseURL(),
            let data = await fetch(AppUpdate.request(for: latestReleaseURL))
        else {
            return nil
        }
        return AppUpdate.decide(
            ownVersion: ownVersion,
            release: AppUpdate.release(from: data),
            skippedVersion: skippedVersion
        )
    }

    /// The bytes one request brings back, or nothing unless the server actually sent them.
    /// `data(for:)` hands back an error page as happily as a file, and a checksum that then
    /// fails to match says "the download is broken" where the truth is "there is no such
    /// file".
    private nonisolated static func fetch(_ request: URLRequest) async -> Data? {
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return nil
        }
        return data
    }

    // MARK: - Asking the person

    private func present(_ outcome: AppUpdateDecision?, announceEveryOutcome: Bool) {
        if case let .available(release) = outcome {
            offer(release)
            return
        }
        // Everything below answers a question the person asked. The launch check asked it
        // for them, and has nothing to say unless there is an update.
        guard announceEveryOutcome else {
            return
        }
        switch outcome {
        case .none:
            inform(title: updateCheckFailedTitle, body: updateCheckFailedBody)
        case .ownVersionUnknown:
            inform(title: updateNoVersionTitle, body: updateNoVersionBody)
        case .upToDate:
            inform(title: updateUpToDateTitle, body: updateUpToDateBody(version: ownVersion ?? ""))
        // A version set aside is only skipped for the launch check. Asking by hand means
        // asking again, which is the only way back from a press nobody can undo otherwise.
        case let .skipped(release):
            offer(release)
        case .available:
            break
        }
    }

    private func offer(_ release: AppRelease) {
        let alert = NSAlert()
        alert.messageText = updateAvailableTitle(version: release.version)
        alert.informativeText = updateAvailableBody(ownVersion: ownVersion ?? "")
        alert.addButton(withTitle: updateDownloadButton)
        alert.addButton(withTitle: updateLaterButton)
        alert.addButton(withTitle: updateSkipButton(version: release.version))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            download(release)
        case .alertThirdButtonReturn:
            preferences.set(release.version, forKey: Key.skippedVersion)
        default:
            break
        }
    }

    private func inform(title: String, body: String, openPageFor release: AppRelease? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        if let release {
            alert.addButton(withTitle: updateOpenPageButton)
            alert.addButton(withTitle: updateCloseButton)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.pageURL)
            }
            return
        }
        alert.addButton(withTitle: updateCloseButton)
        alert.runModal()
    }

    // MARK: - Fetching and installing

    private func download(_ release: AppRelease) {
        guard let downloadURL = release.downloadURL, let checksumURL = release.checksumURL else {
            // A release with no file attached is a release a person has to look at.
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        guard !isWorking else {
            return
        }
        isWorking = true
        let destination = Bundle.main.bundleURL
        Task { [weak self] in
            let staged = await Self.stage(
                downloadURL: downloadURL,
                checksumURL: checksumURL,
                expectedVersion: release.version,
                beside: destination
            )
            guard let self else {
                return
            }
            isWorking = false
            guard let staged else {
                inform(title: updateFailedTitle, body: updateFailedBody, openPageFor: release)
                return
            }
            offerToInstall(staged, release: release, replacing: destination)
        }
    }

    /// Downloads the build, proves it arrived whole, and unpacks it. Returns the unpacked
    /// bundle, or nothing if any step failed.
    ///
    /// The unpacking happens in a temporary folder the system picks **on the same volume as
    /// the copy being replaced**, because an atomic replace works only within one volume.
    ///
    /// The checksum is the release's own `.sha256` file. Over HTTPS it adds little against an
    /// attacker — both files come from the same place — and everything against the ordinary
    /// case: a download cut halfway, a proxy that served a stale copy, a file replaced while
    /// the release was being made. When there is a Developer ID certificate, the signature
    /// takes over this job properly.
    nonisolated static func stage(
        downloadURL: URL,
        checksumURL: URL,
        expectedVersion: String,
        beside destination: URL
    ) async -> URL? {
        let fileManager = FileManager.default
        guard
            let archive = await fetch(URLRequest(url: downloadURL)),
            let checksumData = await fetch(URLRequest(url: checksumURL)),
            let expected = AppUpdate.checksum(fromChecksumFile: String(decoding: checksumData, as: UTF8.self)),
            expected == sha256Hex(of: archive),
            let workingDirectory = try? fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: destination,
                create: true
            )
        else {
            return nil
        }
        // Nothing half-unpacked is left behind on any failure from here on.
        func discard() -> URL? {
            try? fileManager.removeItem(at: workingDirectory)
            return nil
        }
        let archiveURL = workingDirectory.appendingPathComponent("AgentWatch.zip")
        guard (try? archive.write(to: archiveURL)) != nil, unpack(archiveURL, into: workingDirectory) else {
            return discard()
        }
        let unpacked = workingDirectory.appendingPathComponent("AgentWatch.app")
        guard fileManager.fileExists(atPath: unpacked.path), version(ofBundleAt: unpacked) == expectedVersion else {
            return discard()
        }
        return unpacked
    }

    private nonisolated static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `ditto`, because it is the one unpacker that keeps a bundle's symbolic links and
    /// extended attributes — and with them the signature the archive was made with.
    private nonisolated static func unpack(_ archive: URL, into directory: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", archive.path, directory.path]
        guard (try? task.run()) != nil else {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private nonisolated static func version(ofBundleAt url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func offerToInstall(_ staged: URL, release: AppRelease, replacing destination: URL) {
        let alert = NSAlert()
        alert.messageText = updateReadyTitle(version: release.version)
        alert.informativeText = updateReadyBody
        alert.addButton(withTitle: updateInstallButton)
        alert.addButton(withTitle: updateLaterButton)
        guard alert.runModal() == .alertFirstButtonReturn else {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            return
        }
        install(staged, release: release, replacing: destination)
    }

    private func install(_ staged: URL, release: AppRelease, replacing destination: URL) {
        do {
            // An atomic replace rather than delete-then-move: a failure here leaves the copy
            // that works in place, and there is no moment where the app is not installed.
            try FileManager.default.replaceItem(
                at: destination,
                withItemAt: staged,
                backupItemName: nil,
                options: [],
                resultingItemURL: nil
            )
        } catch {
            // Almost always no room to write — a bundle somebody else installed, or one in a
            // folder this person does not own. Nothing is broken; the download is theirs to
            // finish in the Finder.
            NSWorkspace.shared.activateFileViewerSelecting([staged])
            inform(title: updateCannotReplaceTitle, body: updateCannotReplaceBody, openPageFor: release)
            return
        }
        // The archive is still beside the bundle that was just moved into place.
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        relaunch(at: destination)
    }

    /// Starts the copy that is now on disk and leaves.
    ///
    /// The order matters and it is not the obvious one. A second Agent Watch cannot start
    /// while this one holds the socket, so the new copy is opened by a small shell that waits
    /// a moment — it outlives this process — and this one quits immediately afterwards.
    private func relaunch(at bundleURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 2; open \(ShellWord.quoted(bundleURL.path))"]
        guard (try? task.run()) != nil else {
            // Quitting now would take the app off the screen with nothing to bring it back,
            // right after an update that otherwise worked.
            inform(title: updateRelaunchFailedTitle, body: updateRelaunchFailedBody)
            return
        }
        NSApp.terminate(nil)
    }
}
