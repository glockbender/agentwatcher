import Foundation

/// Claude's plan limits as Claude Code itself keeps them, read without asking anyone.
///
/// Every time Claude Code asks the server for the plan's usage — `/usage`, or the
/// `get_usage` request `ClaudeUsageProbe` sends — it writes the answer into its
/// `.claude.json` under `cachedUsageUtilization`, with the time it was fetched and the account
/// it belongs to. Neither the key nor the request is documented; ADR-0026 says why the app
/// reads them anyway and what that costs. Read from the Claude Code 2.1.326 binary.
///
/// Only the two windows the widget shows are taken. The rest of the server's answer — two
/// dozen fields, most of them under code names — is passed through by Claude Code almost as
/// sent, and nothing here should come to depend on it.
public enum ClaudeUsageSnapshot {
    /// Claude Code does not trust its own snapshot past an hour, and neither does the app.
    public static let maximumAge: TimeInterval = 60 * 60

    /// The limits in a `.claude.json`, or `nil` when it holds none the app can trust.
    ///
    /// `nil` covers a file caught mid-write, a snapshot older than `maximumAge`, one fetched
    /// for another account than the one now signed in — Claude Code drops that one itself on
    /// its next read — and a shape the app does not know.
    public static func limits(inConfigFile data: Data, now: Date) -> AgentUsageLimits? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let snapshot = root["cachedUsageUtilization"] as? [String: Any],
            let fetchedAtMilliseconds = snapshot["fetchedAtMs"] as? Double,
            let utilization = snapshot["utilization"] as? [String: Any]
        else {
            return nil
        }
        // Compared, never kept: the account's identifier has no use past this line.
        let signedIn = (root["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
        guard snapshot["accountUuid"] as? String == signedIn else {
            return nil
        }
        let fetchedAt = Date(timeIntervalSince1970: fetchedAtMilliseconds / 1_000)
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= 0, age <= maximumAge else {
            return nil
        }
        return limits(in: utilization, observedAt: fetchedAt)
    }

    /// What one `get_usage` reply said, read from the line of standard output that carries it.
    public enum Reply: Equatable, Sendable {
        case limits(AgentUsageLimits)
        /// The sign-in has no plan limits: an API key, Bedrock, Vertex, or a token without the
        /// scope that reads them. Asking again will not change that.
        case noPlanLimits
        /// Claude Code refused the request — one too old to know it does that.
        case refused
        /// Not the reply to this request, or one of a shape the app does not know.
        case unrecognised
    }

    /// The reply to the `get_usage` request named `requestID`, from one line of output.
    ///
    /// - Parameter now: when the reply arrived. Claude Code may have answered from a snapshot
    ///   up to a minute old, which the reply does not say; a minute is below anything the
    ///   widget shows.
    public static func reply(in line: Data, requestID: String, now: Date) -> Reply {
        guard
            let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            message["type"] as? String == "control_response",
            let response = message["response"] as? [String: Any],
            response["request_id"] as? String == requestID
        else {
            return .unrecognised
        }
        guard response["subtype"] as? String == "success" else {
            return .refused
        }
        guard let body = response["response"] as? [String: Any] else {
            return .unrecognised
        }
        if body["rate_limits_available"] as? Bool == false {
            return .noPlanLimits
        }
        guard
            let windows = body["rate_limits"] as? [String: Any],
            let limits = limits(in: windows, observedAt: now)
        else {
            return .unrecognised
        }
        return .limits(limits)
    }

    /// The request, as the one line written to Claude Code's standard input.
    public static func request(id: String) -> Data {
        let line =
            #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"get_usage","skip_behaviors":true}}"#
        return Data((line + "\n").utf8)
    }

    private static func limits(in windows: [String: Any], observedAt: Date) -> AgentUsageLimits? {
        let fiveHour = window(windows["five_hour"])
        let sevenDay = window(windows["seven_day"])
        guard fiveHour != nil || sevenDay != nil else {
            return nil
        }
        return AgentUsageLimits(source: .claude, fiveHour: fiveHour, sevenDay: sevenDay, observedAt: observedAt)
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard
            let window = value as? [String: Any],
            let utilization = window["utilization"] as? Double,
            utilization.isFinite, utilization >= 0
        else {
            return nil
        }
        // A window can be spent past its limit; the widget says 100%, as the server's own
        // meters do.
        return UsageWindow(
            usedPercentage: min(utilization, 100),
            resetsAt: (window["resets_at"] as? String).flatMap(date)
        )
    }

    /// Claude Code writes `2026-11-20T22:29:59.750056+00:00`: six digits of fraction, which
    /// `ISO8601DateFormatter` refuses, or none at all.
    private static func date(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

/// When the app may start Claude Code to ask for the plan's usage itself.
///
/// Each run is a Claude Code session of its own in the organisation's OpenTelemetry metrics,
/// so the snapshot is the source and a run only tops it up (ADR-0026): while a Claude session
/// is working, when nothing fresher than `interval` is known, and no more often than that.
/// Attempts count, not successes, so a run that fails is not repeated on the next tick.
public struct ClaudeUsageProbePolicy: Equatable, Sendable {
    public static let interval: TimeInterval = 30 * 60

    public private(set) var lastAttemptAt: Date?
    /// Set once a run shows that asking again cannot help, until the app is restarted.
    public private(set) var stopped = false

    public init() {}

    public func shouldProbe(now: Date, knownLimitsObservedAt: Date?, claudeIsWorking: Bool) -> Bool {
        guard !stopped, claudeIsWorking else {
            return false
        }
        if let knownLimitsObservedAt, now.timeIntervalSince(knownLimitsObservedAt) < Self.interval {
            return false
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.interval {
            return false
        }
        return true
    }

    public mutating func recordAttempt(at moment: Date) {
        lastAttemptAt = moment
    }

    public mutating func stop() {
        stopped = true
    }
}
