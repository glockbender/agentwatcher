import Foundation

/// The one update message the app shows itself; every other one is Sparkle's window.
///
/// Only ever seen by somebody running the app from a build directory, where Sparkle is never
/// started — reached by pressing Check Now there.
let updateNoVersionTitle = "This build has no version"
let updateNoVersionBody = """
    It was started from a build directory rather than from an application bundle, so there is \
    nothing to compare against a release.
    """
