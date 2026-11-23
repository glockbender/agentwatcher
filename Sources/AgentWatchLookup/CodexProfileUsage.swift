import AgentWatchCore
import Foundation

/// One dated, default Codex quota reading from one chat. Token totals belong to that chat only.
public struct CodexProfileUsage: Equatable, Sendable {
    public let limits: AgentUsageLimits
    public let chatTokens: Int?
    public let sessionLabel: String

    public static func latest(in folder: URL, sessionLabels: [String], transcriptFiles: TitleFileSystem?) -> Self? {
        guard let transcriptFiles, !Task.isCancelled else { return nil }
        let root = TranscriptLocator.root(for: .codex, inFolder: folder)
        let files = TranscriptLocator.uniqueMatches(sessionLabels: Set(sessionLabels), source: .codex, roots: [root])
        var newest: Self?
        for label in sessionLabels {
            guard !Task.isCancelled else { break }
            guard let file = files[label], ProjectSessionLookup.isRegularTranscript(file),
                let tail = transcriptFiles.readTail(file.path, SessionDescriptionResolver.transcriptTailByteCount),
                let reading = latest(inTail: tail, sessionLabel: label),
                newest.map({ $0.limits.observedAt < reading.limits.observedAt }) ?? true
            else { continue }
            newest = reading
        }
        return newest
    }

    static func latest(inTail data: Data, sessionLabel: String) -> Self? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var newest: Self?
        for line in data.split(separator: 10) where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
            guard let record = try? decoder.decode(Record.self, from: line),
                record.type == "event_msg", record.payload.type == "token_count",
                let limits = record.payload.rateLimits, limits.limitId == nil || limits.limitId == "codex",
                let date = fractional.date(from: record.timestamp) ?? plain.date(from: record.timestamp),
                newest.map({ $0.limits.observedAt <= date }) ?? true
            else { continue }
            let windows = [limits.primary, limits.secondary].compactMap { $0 }
            let fiveHour = windows.first { $0.windowMinutes == 300 }?.usage
            let sevenDay = windows.first { $0.windowMinutes == 10_080 }?.usage
            guard fiveHour != nil || sevenDay != nil else { continue }
            let tokens = record.payload.info?.totalTokenUsage?.totalTokens
            newest = Self(
                limits: AgentUsageLimits(source: .codex, fiveHour: fiveHour, sevenDay: sevenDay, observedAt: date),
                chatTokens: tokens.flatMap { $0 >= 0 ? $0 : nil }, sessionLabel: sessionLabel)
        }
        return newest
    }

    private struct Record: Decodable {
        let type: String
        let timestamp: String
        let payload: Payload
        struct Payload: Decodable {
            let type: String
            let rateLimits: Limits?
            let info: Info?
        }
        struct Info: Decodable { let totalTokenUsage: Tokens? }
        struct Tokens: Decodable { let totalTokens: Int? }
        struct Limits: Decodable {
            let limitId: String?
            let primary: Window?
            let secondary: Window?
        }
        struct Window: Decodable {
            let usedPercent: Double
            let windowMinutes: Int?
            let resetsAt: Double?
            var usage: UsageWindow? {
                guard (0...100).contains(usedPercent) else { return nil }
                return UsageWindow(
                    usedPercentage: usedPercent, resetsAt: UsageWindow.resetDate(unixSeconds: resetsAt))
            }
        }
    }
}
