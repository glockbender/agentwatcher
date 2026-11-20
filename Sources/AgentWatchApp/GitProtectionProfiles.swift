import AgentWatchCore
import SwiftUI

struct GitProtectionProfiles: View {
    let folders: AgentFolders
    @State private var source = AgentSource.claude
    @State private var selected: URL?
    @State private var state: GitHookInstaller.State?
    @State private var error: String?
    @State private var legacy: MothershipGitRegistration.State?
    @State private var confirmRemoval = false
    private var profile: URL { selected ?? folders.defaultFolder(for: source) }

    var body: some View {
        Section("Protect Git commands") {
            Picker("Client", selection: $source) {
                Text("Claude").tag(AgentSource.claude)
                Text("Codex").tag(AgentSource.codex)
            }.pickerStyle(.segmented)
            Picker("Profile", selection: Binding(get: { profile }, set: { selected = $0 })) {
                ForEach(folders.folders(for: source), id: \.self) { path in
                    Text(path.path).tag(path)
                }
            }
            if state == .registered {
                Text("Git hook registered in this profile.")
                Button("Remove Git Hook…") { confirmRemoval = true }
            } else {
                Button(state == .needsRepair ? "Repair Git Hook" : "Install Git Hook") { apply(.install) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Footnote(
                source == .codex
                    ? "After installation, open /hooks in Codex and approve this PreToolUse hook. Reopen the chat to load the configuration."
                    : "Open a new Claude conversation to load the registered hook.")
            if legacy == .registered {
                Label(
                    "This profile still registers Git protection through Mothership.",
                    systemImage: "exclamationmark.triangle")
            }
            Footnote(
                "Moving from Mothership? Register the Agent Watch hook first and review it in your client. Then update Mothership to the version without its Git hook and reopen the client."
            )
        }
        .task(id: source.rawValue + profile.path) {
            let source = source
            let folder = profile
            legacy = nil
            let state = await Task.detached(priority: .utility) {
                MothershipGitRegistration.check(source: source, profile: folder)
            }.value
            if !Task.isCancelled { legacy = state }
        }
        .onAppear { apply(.status) }
        .onChange(of: source) {
            selected = nil
            apply(.status)
        }
        .onChange(of: selected) { apply(.status) }
        .confirmationDialog("Remove Git protection from this profile?", isPresented: $confirmRemoval) {
            Button("Remove Git Hook", role: .destructive) { apply(.remove) }
        }
    }

    private func apply(_ action: GitHookInstaller.Action) {
        error = nil
        do {
            state = try GitHookInstaller(bundle: Bundle.main.bundleURL).apply(action, source: source, profile: profile)
        } catch {
            state = nil
            self.error = error.localizedDescription
        }
    }
}
