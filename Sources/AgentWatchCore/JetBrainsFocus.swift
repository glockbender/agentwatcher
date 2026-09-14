import Foundation

/// Why Agent Watch will not ask an IDE to select the session's tab.
///
/// Four named reasons rather than one `nil`, because they call for four different answers.
/// One of them means the host is simply not a JetBrains IDE and nothing is wrong; the other
/// three are things a person can fix, and the installation screen is where they get said.
public enum JetBrainsFocusRefusal: String, Equatable, Sendable {
    /// Not a JetBrains IDE at all — Ghostty, Terminal, anything else. The ordinary case.
    case notAJetBrainsIDE

    /// A JetBrains IDE whose bundle registers no URL scheme. There is no name to address it
    /// by, and guessing one from the product name is exactly the guess that breaks: IntelliJ
    /// IDEA answers to `idea`, which no rule derives from "IntelliJ IDEA".
    case bundleNamesNoScheme

    /// The `jetbrains://` scheme belongs to the JetBrains daemon, not to any IDE — measured
    /// on this machine, where it is claimed by the daemon helper and by Toolbox. Without it
    /// the address goes nowhere *and says nothing*, which is the worst shape a failure can
    /// take: the click would look as though it had worked.
    case daemonMissing

    /// The plugin has never answered from this IDE, so there is nothing at the far end.
    case pluginNeverAnswered
}

/// Asking a JetBrains IDE to bring the session's terminal tab forward.
///
/// The transport is one URL. The platform registers the scheme, routes the address to the
/// plugin and runs it, so there is no socket, no port and no permission anywhere in this —
/// see `docs/session-focus-research.md`.
///
/// Everything here is a rule over values somebody else read, which is why it lives in the
/// core: the four preconditions are four file-system questions, and a rule about their
/// answers is tested without a disk or an IDE.
public enum JetBrainsFocus {
    /// What one click on a session's row should do, once the host has been raised.
    public enum Decision: Equatable, Sendable {
        case ask(URL)
        case decline(JetBrainsFocusRefusal)
    }

    /// Whether to ask, and what to ask, in the order the reasons are worth reporting.
    ///
    /// - Parameters:
    ///   - dataDirectoryName: from the bundle's `product-info.json`; `nil` for anything that
    ///     is not a JetBrains IDE.
    ///   - productScheme: from the bundle's `CFBundleURLSchemes` — `goland`, `pycharm`,
    ///     `idea`. Taken from the bundle rather than derived, and validated here because a
    ///     bundle is not ours to trust: it is being pasted into a URL.
    ///   - isDaemonInstalled: whether [daemonBundle] exists.
    ///   - hasAnsweredPing: whether the plugin's reply file for this IDE exists.
    public static func decision(
        dataDirectoryName: String?,
        productScheme: String?,
        isDaemonInstalled: Bool,
        hasAnsweredPing: Bool,
        agentProcessID: Int32
    ) -> Decision {
        guard dataDirectoryName?.isEmpty == false else {
            return .decline(.notAJetBrainsIDE)
        }
        guard let productScheme, isAddressableScheme(productScheme) else {
            return .decline(.bundleNamesNoScheme)
        }
        guard isDaemonInstalled else {
            return .decline(.daemonMissing)
        }
        guard hasAnsweredPing else {
            return .decline(.pluginNeverAnswered)
        }
        guard let url = focusURL(productScheme: productScheme, agentProcessID: agentProcessID) else {
            return .decline(.bundleNamesNoScheme)
        }
        return .ask(url)
    }

    /// The address itself.
    public static func focusURL(productScheme: String, agentProcessID: Int32) -> URL? {
        guard isAddressableScheme(productScheme) else {
            return nil
        }
        return URL(string: "jetbrains://\(productScheme)/agent-watch/focus?pid=\(agentProcessID)")
    }

    /// The bundle that owns the `jetbrains://` scheme.
    ///
    /// Installed by the IDE itself and also by Toolbox — both were seen claiming the scheme
    /// on this machine, and this is the copy the IDE keeps, so it is the one that is there
    /// for somebody who never installed Toolbox.
    public static func daemonBundle(userHome: URL) -> URL {
        userHome
            .appendingPathComponent("Library/Application Support/JetBrains/Daemon/bundles/current", isDirectory: true)
            .appendingPathComponent("jetbrainsd.app", isDirectory: true)
    }

    /// A URL scheme, by RFC 3986: a letter, then letters, digits, `+`, `-` and `.`.
    ///
    /// Checked because the value is read out of somebody else's application bundle and then
    /// pasted into a URL. A scheme with a `/` in it would not be a scheme, it would be a
    /// second path segment, and the command the IDE ran would not be the one written here.
    ///
    /// Public because it is the one check, and every address built for an IDE goes through
    /// it — the two the installation screen sends as well as the one this file sends. See
    /// `IDEPluginInstallation`.
    public static func isAddressableScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isLetter, first.isASCII else {
            return false
        }
        return scheme.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "+-.".contains(character))
        }
    }
}
