import AgentWatchCore
import AgentWatchLookup
import SwiftUI

/// A profile here is the named local agent folder that produced the sample. It does not identify
/// the signed-in account: two folders can use one account, and one folder can switch accounts.
struct UsageProfilesView: View {
    let folders: AgentFolders
    let defaultClaudeUsage: AgentUsageLimits?
    let sessions: [SessionSnapshot]
    let readsTranscripts: Bool
    @State private var codex: [URL: CodexProfileUsage] = [:]
    @State private var indexes: [URL: CodexTranscriptIndex] = [:]
    @State private var loading = false
    @State private var reload = 0

    enum CodexStatus: Equatable {
        case transcriptsOff, reading, found(CodexProfileUsage), none
    }

    /// A reading already shown stays while a newer one is read; with none yet, the page says it
    /// is still reading rather than that there is nothing to find.
    static func codexStatus(readsTranscripts: Bool, usage: CodexProfileUsage?, loading: Bool) -> CodexStatus {
        guard readsTranscripts else { return .transcriptsOff }
        if let usage { return .found(usage) }
        return loading ? .reading : .none
    }

    private struct Request: Equatable {
        let folders: [URL]
        let labels: [String]
        let reload: Int
        let readsTranscripts: Bool
    }

    var body: some View {
        let request = Request(
            folders: folders.folders(for: .codex),
            labels: Array(Set(sessions.filter { $0.source == .codex }.map(\.transcriptLabel))).sorted(),
            reload: reload, readsTranscripts: readsTranscripts)
        VStack(alignment: .leading) {
            HStack {
                Text("Usage by profile").font(.title2.bold())
                Spacer()
                Button("Refresh") {
                    indexes = [:]
                    reload += 1
                }.keyboardShortcut("r", modifiers: .command)
            }
            Text("Each profile is a local agent folder. Its last reading may belong to a previous sign-in.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    Section(source == .claude ? "Claude" : "Codex") {
                        ForEach(folders.folders(for: source), id: \.self) { folder in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(folder.path).font(.headline).textSelection(.enabled)
                                let status = Self.codexStatus(
                                    readsTranscripts: readsTranscripts, usage: codex[folder], loading: loading)
                                if source == .claude {
                                    if folder != folders.defaultFolder(for: .claude) {
                                        Text("Claude quota is available for the default profile.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else if let defaultClaudeUsage {
                                        reading(defaultClaudeUsage)
                                    } else {
                                        Text("No quota recorded for the default profile.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                } else if status == .transcriptsOff {
                                    Text("Transcript reading is off in General settings.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if status == .reading {
                                    Text("Reading this profile’s transcripts…")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if case .found(let usage) = status {
                                    reading(usage.limits)
                                    if let count = usage.chatTokens,
                                        let session = sessions.first(where: {
                                            $0.source == .codex && $0.transcriptLabel == usage.sessionLabel
                                        })
                                    {
                                        Text(
                                            "Tokens in \(session.title ?? "the observed chat") at this reading: \(count.formatted())"
                                        )
                                        .font(.caption)
                                    }
                                } else {
                                    Text("No dated quota found in observed chats in this profile.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }.padding()
            .task(id: request) {
                guard request.readsTranscripts, !Task.isCancelled else {
                    codex = [:]
                    loading = false
                    return
                }
                loading = true
                let known = indexes
                let worker = Task.detached(priority: .utility) {
                    var values: [URL: CodexProfileUsage] = [:]
                    var updated = known
                    for folder in request.folders {
                        guard !Task.isCancelled else { break }
                        var index = updated[folder] ?? CodexTranscriptIndex()
                        index.locate(Set(request.labels), in: folder)
                        updated[folder] = index
                        values[folder] = CodexProfileUsage.latest(
                            in: index, sessionLabels: request.labels, transcriptFiles: .live)
                    }
                    return (values, updated)
                }
                let (values, updated) = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                codex = values
                indexes = updated
                loading = false
            }
    }

    @ViewBuilder
    private func reading(_ limits: AgentUsageLimits) -> some View {
        Text("Observed \(limits.observedAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
        window("5 hours", limits.fiveHour)
        window("7 days", limits.sevenDay)
    }

    @ViewBuilder
    private func window(_ name: String, _ window: UsageWindow?) -> some View {
        if let window {
            HStack {
                Text(name)
                Text(
                    "\((100 - window.usedPercentage).formatted(.number.precision(.fractionLength(0...1))))% remaining at reading"
                )
                if let date = window.resetsAt {
                    Text("Renewal \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text("Renewal unknown")
                }
            }.font(.caption)
        }
    }
}
