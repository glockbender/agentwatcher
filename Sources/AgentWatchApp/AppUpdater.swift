import AgentWatchCore
import AppKit
import Sparkle

/// Finding out that a newer build exists, and putting it in place — through Sparkle.
///
/// Sparkle owns the windows: the offer with the list of changes, the download with its
/// progress and its Cancel, the install and the relaunch. What stays here is what this app
/// promises about them:
///
/// - **Nothing about the person leaves the machine.** The feed is a file in the latest GitHub
///   release; Sparkle's system profile stays off, and every request introduces the app as
///   `AppUpdate.userAgent`, without the version Sparkle would otherwise add.
/// - **One setting decides whether it looks by itself**, the one on the General page. Sparkle
///   never asks its own "check automatically?" on top of it.
/// - **The list of changes is the part of `CHANGELOG.md` the person has not seen**: the feed
///   carries the whole file and `Changelog.unseen` cuts it to the versions between the one
///   running and the one offered.
///
/// An update is accepted when its EdDSA signature matches the key in `Info.plist`
/// (`SUPublicEDKey`): the build is signed ad-hoc, so its Apple signature changes with every
/// build and cannot be what proves the update came from here.
@MainActor
final class AppUpdater: NSObject, PreferenceDefaults {
    private enum Key {
        static let checksOnLaunch = "checkForUpdatesOnLaunch"
    }

    private let preferences: PreferenceFile
    private var controller: SPUStandardUpdaterController?
    private var launchCheck: Task<Void, Never>?

    /// The version of the running copy, or nothing when there is no bundle to ask.
    ///
    /// `swift run` produces a bare executable with no `Info.plist`: Sparkle has no feed to
    /// read there and nothing to replace, so it is never started.
    let ownVersion: String?

    init(preferences: PreferenceFile, bundle: Bundle = .main) {
        self.preferences = preferences
        ownVersion =
            bundle.bundleURL.pathExtension == "app"
            ? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            : nil
        super.init()
    }

    nonisolated var defaultValues: [String: JSONValue] {
        [Key.checksOnLaunch: .bool(true)]
    }

    var checksOnLaunch: Bool {
        get { preferences.flag(forKey: Key.checksOnLaunch) ?? true }
        set {
            preferences.set(newValue, forKey: Key.checksOnLaunch)
            controller?.updater.automaticallyChecksForUpdates = newValue
            if !newValue {
                launchCheck?.cancel()
            }
        }
    }

    /// Starts Sparkle a few seconds after launch, so the check does not compete with what the
    /// person opened the app for, and looks for an update right away if the setting is on.
    @discardableResult
    func checkAfterLaunch(after delay: Duration = .seconds(5)) -> Task<Void, Never>? {
        launchCheck?.cancel()
        guard ownVersion != nil else {
            return nil
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            let updater = startedUpdater()
            // Sparkle's own advice for a check on every launch: right after starting, and only
            // while automatic checks are on. Later on it keeps to its daily schedule.
            if checksOnLaunch {
                updater?.checkForUpdatesInBackground()
            }
        }
        launchCheck = task
        return task
    }

    /// The check a person asked for, which answers even when there is nothing to say.
    func checkNow() {
        guard ownVersion != nil else {
            let alert = NSAlert()
            alert.messageText = updateNoVersionTitle
            alert.informativeText = updateNoVersionBody
            alert.runModal()
            return
        }
        launchCheck?.cancel()
        startedUpdater()?.checkForUpdates()
    }

    /// The one updater, made on first use. Settings that Sparkle would otherwise read from its
    /// own defaults are set here, each time, from this app's preferences.
    @discardableResult
    private func startedUpdater() -> SPUUpdater? {
        if let controller {
            return controller.updater
        }
        let made = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        let updater = made.updater
        updater.userAgentString = AppUpdate.userAgent
        updater.sendsSystemProfile = false
        updater.automaticallyChecksForUpdates = checksOnLaunch
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
        } catch {
            Self.diagnostic("Sparkle did not start: \(error.localizedDescription)")
            return nil
        }
        controller = made
        return updater
    }

    /// Opted into only by the debug end-to-end harness, which reads standard error.
    nonisolated static func diagnostic(_ message: String) {
        #if DEBUG
            guard ProcessInfo.processInfo.environment["AGENT_WATCH_UPDATE_DIAGNOSTICS"] == "1" else {
                return
            }
            try? FileHandle.standardError.write(contentsOf: Data("Update: \(message)\n".utf8))
        #endif
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// A debug build takes `AGENT_WATCH_UPDATE_FEED` instead of `SUFeedURL` when it is set: the
    /// end-to-end test points it at a local server that plays the latest release. A release
    /// build ignores the variable.
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
            if let feed = ProcessInfo.processInfo.environment["AGENT_WATCH_UPDATE_FEED"], !feed.isEmpty {
                return feed
            }
        #endif
        return nil
    }

    /// The General page already holds this choice; a second question about it would be noise.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Self.diagnostic("aborted: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.diagnostic("found \(item.displayVersionString)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Self.diagnostic("no update")
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// The changes since the running version, rather than the whole file the feed carries.
    nonisolated func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotesAttributedString: NSAttributedString,
        forUpdate update: SUAppcastItem,
        withBundleDisplayVersion bundleDisplayVersion: String,
        bundleVersion: String
    ) -> NSAttributedString? {
        guard
            let changelog = update.itemDescription,
            let unseen = Changelog.unseen(
                in: changelog,
                installed: bundleDisplayVersion,
                offered: update.displayVersionString
            )
        else {
            return nil
        }
        return ChangelogText.attributed(unseen)
    }
}
