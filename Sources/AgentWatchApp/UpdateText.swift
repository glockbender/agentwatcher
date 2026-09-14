import Foundation

/// What the update dialogs say.
///
/// One version number per sentence and no adjectives: the person is being interrupted, and
/// the only question worth their attention is whether to take the new build now.

let updateDownloadButton = "Download"
let updateInstallButton = "Install and Relaunch"
let updateLaterButton = "Not Now"
let updateOpenPageButton = "Open Release Page"
let updateCloseButton = "OK"

func updateSkipButton(version: String) -> String {
    "Skip \(version)"
}

func updateAvailableTitle(version: String) -> String {
    "Agent Watch \(version) is available"
}

func updateAvailableBody(ownVersion: String) -> String {
    """
    You have \(ownVersion). The download is about a megabyte and is installed by the app \
    itself, which then restarts.
    """
}

func updateReadyTitle(version: String) -> String {
    "Agent Watch \(version) is ready"
}

let updateReadyBody = """
    Installing replaces this copy and starts the new one. Sessions already being watched are \
    remembered and come back.
    """

let updateUpToDateTitle = "No update yet"

func updateUpToDateBody(version: String) -> String {
    "Agent Watch \(version) is the newest published build."
}

let updateCheckFailedTitle = "Could not check for updates"
let updateCheckFailedBody = "GitHub could not be reached. Nothing else is affected."

let updateFailedTitle = "Could not download the update"
let updateFailedBody = """
    The file did not arrive whole, or could not be unpacked. This copy is untouched — the \
    release page has the file to install by hand.
    """

let updateCannotReplaceTitle = "Could not replace this copy"
let updateCannotReplaceBody = """
    The new build was downloaded but this copy could not be written over, which usually means \
    it sits somewhere this account cannot change. The downloaded build is selected in the \
    Finder; move it over the old one yourself.
    """

/// Only ever seen by somebody running the app from a build directory, where the check is off
/// anyway — reached by pressing the menu item there.
let updateNoVersionTitle = "This build has no version"
let updateNoVersionBody = """
    It was started from a build directory rather than from an application bundle, so there is \
    nothing to compare against a release.
    """

let updateRelaunchFailedTitle = "Update installed, but the restart failed"
let updateRelaunchFailedBody = """
    The new version is in place. This window belongs to the old one, still running — quit it and \
    open Agent Watch again.
    """
