import AgentWatchCore
import SwiftUI

struct GitProtectionProfiles: View {
    let folders: AgentFolders

    var body: some View {
        Section("Agent profiles") {
            ForEach(AgentSource.allCases, id: \.self) { source in
                ForEach(folders.folders(for: source), id: \.self) { profile in
                    GitProtectionProfile(
                        source: source, profile: profile,
                        displayPath: folders.isDefault(profile, for: source)
                            ? "~/" + profile.lastPathComponent : profile.path
                    )
                }
            }
        }
    }
}

private struct GitProtectionProfile: View {
    let source: AgentSource
    let profile: URL
    let displayPath: String
    @State private var state: GitHookInstaller.State?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var confirmsRemoval = false

    private var client: String { source == .claude ? "Claude Code" : "Codex" }

    private var status: (title: String, color: Color) {
        switch state {
        case .registered: ("Installed", .green)
        case .needsRepair: ("Needs repair", .orange)
        case .absent: ("Not installed", .secondary)
        case nil: (errorMessage == nil ? "Checking…" : "Status unavailable", .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client)
                    Text(displayPath).font(.caption).foregroundStyle(.secondary)
                        .truncationMode(.middle).lineLimit(1).help(profile.path)
                }
                Spacer(minLength: 4)
                Label {
                    Text(status.title).fixedSize()
                } icon: {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                }
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityLabel(status.title)
                switch state {
                case .registered:
                    Button("Remove…") { confirmsRemoval = true }
                case .needsRepair:
                    Button("Repair…") { start(.install) }
                case .absent:
                    Button("Install…") { start(.install) }
                case nil:
                    if errorMessage != nil {
                        Button("Retry") { start(.status) }
                    } else {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                }
            }
            .disabled(busy)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            } else if state == .registered {
                Text(
                    source == .codex
                        ? "In Codex, review hook trust in Settings → Hooks or /hooks, then open a new chat."
                        : "Open a new Claude Code chat to load the installed hook."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else if state == .needsRepair {
                Text("Agent Watch found an outdated or customized Git hook in this profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await apply(.status) }
        .alert("Remove Git hook?", isPresented: $confirmsRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Hook", role: .destructive) { start(.remove) }
        } message: {
            Text("Commands from this \(client) profile will stop going through Agent Watch’s Git checks.")
        }
    }

    private func start(_ action: GitHookInstaller.Action) {
        busy = true
        Task { await apply(action) }
    }

    private func apply(_ action: GitHookInstaller.Action) async {
        let installer = GitHookInstaller(bundle: Bundle.main.bundleURL)
        let result = await Task.detached(priority: .utility) { [source, profile] in
            Result { try installer.apply(action, source: source, profile: profile) }
        }.value
        guard !Task.isCancelled else { return }
        busy = false
        switch result {
        case .success(let state):
            self.state = state
            errorMessage = nil
        case .failure(let error):
            if action == .status { state = nil }
            errorMessage = error.localizedDescription
        }
    }
}
