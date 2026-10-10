/// What the app says about itself when it asks whether a newer build exists.
public enum AppUpdate {
    /// How every request about updating introduces the app: its name, and not its version.
    ///
    /// Set because it would otherwise be set for us: measured on macOS 15.3.1, `URLSession`
    /// introduces a request as `<executable>/<CFBundleVersion> CFNetwork/… Darwin/…`, and
    /// Sparkle's own default is `<name>/<version> Sparkle/<version>`. Either way the bundle's
    /// version is the release version — the one thing these requests promise not to carry.
    /// GitHub wants some name here; it gets the app's and nothing more.
    public static let userAgent = "AgentWatch"
}
