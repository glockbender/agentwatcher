import Foundation

/// The IDE plugin's own answer, as it wrote it.
///
/// One file per IDE settings directory, written by the plugin when Agent Watch opens
/// `…/agent-watch/ping?token=…`. The token is what makes it an answer rather than a file from
/// last week: Agent Watch invents one per question, and only a reply carrying that token says
/// anything about now.
public struct IDEPluginReply: Equatable, Sendable {
    public let token: String
    public let pluginVersion: String?
    public let ideBuild: String?
    public let answeredAt: Date?

    public init(token: String, pluginVersion: String?, ideBuild: String?, answeredAt: Date?) {
        self.token = token
        self.pluginVersion = pluginVersion
        self.ideBuild = ideBuild
        self.answeredAt = answeredAt
    }

    /// Reads one reply file. Bytes in, value out — the file is opened by whoever owns disks.
    ///
    /// Everything but the token is optional, because everything but the token is a detail: a
    /// reply whose version field the next plugin renames still proves the plugin answered.
    public static func parse(_ data: Data) -> IDEPluginReply? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = object["token"] as? String,
            !token.isEmpty
        else {
            return nil
        }
        return IDEPluginReply(
            token: token,
            pluginVersion: text(object["pluginVersion"]),
            ideBuild: text(object["ideBuild"]),
            answeredAt: text(object["answeredAt"]).flatMap(instant)
        )
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// The instant the plugin wrote, in both shapes it writes it in.
    ///
    /// Java's `Instant.toString()` leaves the fractional part out when it is zero, and one
    /// `ISO8601DateFormatter` reads only one of the two: without `.withFractionalSeconds` it
    /// rejects `…:45.031Z`, with it, `…:45Z`. A single formatter would lose the date on
    /// whole-second replies alone — roughly one in a million, which is to say the report
    /// would be right every time anybody checked.
    private static func instant(_ text: String) -> Date? {
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]), [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}

/// Where one check of one IDE stands.
///
/// Three states rather than a token and a flag, because the middle one is a real answer: a
/// `ping` is out and nothing has come back **yet** is not the same as nothing came back.
public enum IDEPluginCheck: Equatable, Sendable {
    /// Nothing has been asked of this IDE in this sitting.
    case notAsked
    /// The address has been opened and the reply has not arrived.
    case waiting(token: String)
    /// The wait is over. A reply carrying this token means the plugin is loaded; no such
    /// reply means it is not — and that is the one way to learn it.
    case done(token: String)

    var token: String? {
        switch self {
        case .notAsked: nil
        case .waiting(let token), .done(let token): token
        }
    }
}

/// Whether the plugin is in one IDE, in the shapes that answer differs in.
///
/// The order is the order they have to be asked in. An IDE nothing can address cannot be
/// pinged, so "never answered" there would be a claim about a question that was never put —
/// the state is unknowable rather than absent, and the two need different sentences.
public enum IDEPluginPresence: Equatable, Sendable {
    /// No `jetbrains://` address reaches this IDE at all: the bundle names no scheme, or the
    /// daemon that owns the scheme is not installed.
    case unaddressable(JetBrainsFocusRefusal)

    /// Addressable, and the plugin has never written a reply for this IDE.
    case neverAnswered

    /// A reply is there from some earlier moment. It outlives the plugin — nothing deletes it
    /// when the plugin is removed — so it says "was loaded here", not "is loaded now".
    case answeredEarlier(IDEPluginReply)

    /// A `ping` has gone out and its answer has not arrived.
    case checking

    /// Asked, waited, and nothing carrying this question's token came back. The one state
    /// that proves the plugin is **not** loaded, which is why an old reply beside it changes
    /// nothing: the file outlives the plugin and silence does not.
    case askedAndSilent(IDEPluginReply?)

    /// The plugin answered the token Agent Watch has just sent. The only state that says
    /// anything about the present.
    case confirmed(IDEPluginReply)

    /// The reply behind this state, when there is one.
    public var reply: IDEPluginReply? {
        switch self {
        case .unaddressable, .neverAnswered, .checking: nil
        case .askedAndSilent(let reply): reply
        case .answeredEarlier(let reply), .confirmed(let reply): reply
        }
    }
}

/// One plugin file waiting to be installed, as its name describes it.
public struct StagedIDEPlugin: Equatable, Sendable {
    public let fileName: String
    public let version: String

    public init(fileName: String, version: String) {
        self.fileName = fileName
        self.version = version
    }
}

/// The rules behind the installation section of the tooling window.
///
/// All of them are rules over values somebody else read — a file's bytes, a directory's file
/// names, a bundle's fields — which is why they are here: what the screen claims about an
/// installation is then checkable without an IDE, a daemon or a disk.
public enum IDEPluginInstallation {
    /// Where this IDE stands, given what is on disk and what has just been asked of it.
    ///
    /// - Parameter check: what this sitting has asked of this IDE. Without a check nothing is
    ///   known about now, which is why an untouched window says "answered earlier" and never
    ///   "installed": the reply file outlives the plugin that wrote it.
    public static func presence(
        productScheme: String?,
        isDaemonInstalled: Bool,
        reply: IDEPluginReply?,
        check: IDEPluginCheck
    ) -> IDEPluginPresence {
        guard let productScheme, JetBrainsFocus.isAddressableScheme(productScheme) else {
            return .unaddressable(.bundleNamesNoScheme)
        }
        guard isDaemonInstalled else {
            return .unaddressable(.daemonMissing)
        }
        // Ahead of every other reading of the file: a reply to this question is the only one
        // that describes the present, whatever else is on disk.
        if let reply, let token = check.token, reply.token == token {
            return .confirmed(reply)
        }
        switch check {
        case .waiting:
            return .checking
        case .done:
            return .askedAndSilent(reply)
        case .notAsked:
            return reply.map { .answeredEarlier($0) } ?? .neverAnswered
        }
    }

    /// The plugin file Agent Watch would hand to an IDE, out of whatever is in the directory
    /// it keeps them in.
    ///
    /// The name carries the version, which is the whole reason to read names at all: it is
    /// what lets a row say that the IDE answered an older one. Several can be there — a
    /// release downloaded beside the one before it — and the highest version wins.
    public static func stagedPlugin(among fileNames: [String]) -> StagedIDEPlugin? {
        fileNames
            .compactMap { name -> StagedIDEPlugin? in
                guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else {
                    return nil
                }
                let version = String(name.dropFirst(filePrefix.count).dropLast(fileSuffix.count))
                return version.isEmpty ? nil : StagedIDEPlugin(fileName: name, version: version)
            }
            .max { ReleaseVersion.isNewer($1.version, than: $0.version) }
    }

    /// A token for one `ping`.
    ///
    /// Shaped to what the plugin accepts rather than to what is convenient here: it refuses
    /// anything that is not letters and digits, and that refusal is the plugin's protection
    /// against an address it did not come from — any page in a browser can open a
    /// `jetbrains://` link.
    public static func newToken() -> String {
        String((0..<24).map { _ in tokenAlphabet.randomElement() ?? "0" })
    }

    /// The plugin's own rule, written here so a change on one side fails a test rather than a
    /// check nobody can explain. See `InstallationReport.acceptedToken` in `ide-plugin/`.
    public static func isAcceptableToken(_ token: String) -> Bool {
        (8...64).contains(token.count) && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The address that asks one IDE whether the plugin is loaded in it.
    ///
    /// Same command as the jump to a tab, different target. Nothing comes back along the
    /// address — the answer is the file the plugin writes, and the token is how a reply is
    /// told apart from the one before it.
    public static func pingURL(productScheme: String, token: String) -> URL? {
        guard JetBrainsFocus.isAddressableScheme(productScheme), isAcceptableToken(token) else {
            return nil
        }
        return URL(string: "jetbrains://\(productScheme)/agent-watch/ping?token=\(token)")
    }

    /// The address that opens this IDE's Plugins page.
    ///
    /// `settings` is the platform's own command, not ours — there is no command for
    /// installing a plugin, so this is as far as an address can carry a person. The dialog
    /// behind the gear on that page is the IDE's, and it is the thing that installs.
    public static func pluginsPageURL(productScheme: String) -> URL? {
        guard JetBrainsFocus.isAddressableScheme(productScheme) else {
            return nil
        }
        return URL(string: "jetbrains://\(productScheme)/settings?name=Plugins")
    }

    private static let filePrefix = "agent-watch-ide-"
    private static let fileSuffix = ".zip"
    private static let tokenAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
}
