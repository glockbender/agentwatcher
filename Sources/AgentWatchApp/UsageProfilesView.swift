import AgentWatchCore
import AgentWatchLookup
import SwiftUI

/// A profile here is the named local agent folder that produced the sample. It does not identify
/// the signed-in account: two folders can use one account, and one folder can switch accounts.
struct UsageProfilesView: View {
    let folders: AgentFolders
    let claude: [String: AgentUsageLimits]
    let sessions: [SessionSnapshot]
    let readsTranscripts: Bool
    @State private var codex: [URL: CodexProfileUsage] = [:]
    @State private var reload = 0

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
                Button("Refresh") { reload += 1 }.keyboardShortcut("r", modifiers: .command)
            }
            Text("Each profile is a local agent folder. Its last reading may belong to a previous sign-in.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    Section(source == .claude ? "Claude" : "Codex") {
                        ForEach(folders.folders(for: source), id: \.self) { folder in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(folder.path).font(.headline).textSelection(.enabled)
                                if source == .claude, let limits = claude[AgentFolders.label(of: folder)] {
                                    reading(limits)
                                } else if source == .codex && !readsTranscripts {
                                    Text("Transcript reading is off in General settings.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if source == .codex, let usage = codex[folder] {
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
                                    Text(
                                        source == .claude
                                            ? "No quota reported by this profile’s status line during this launch."
                                            : "No dated quota found in observed chats in this profile."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }.padding()
            .task(id: request) {
                codex = [:]
                guard request.readsTranscripts, !Task.isCancelled else { return }
                let worker = Task.detached(priority: .utility) {
                    var values: [URL: CodexProfileUsage] = [:]
                    for folder in request.folders {
                        guard !Task.isCancelled else { break }
                        values[folder] = CodexProfileUsage.latest(
                            in: folder, sessionLabels: request.labels, transcriptFiles: .live)
                    }
                    return values
                }
                let values = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if !Task.isCancelled { codex = values }
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
