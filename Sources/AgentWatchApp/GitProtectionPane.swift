import AgentWatchCore
import AgentWatchGit
import SwiftUI
import UniformTypeIdentifiers

struct GitProtectionPane: View {
    let profiles: AgentFolders
    @State private var folder: URL?
    @State private var branch = "release"
    @State private var choosingFolder = false
    @State private var reading = false
    @State private var previewTask: Task<Void, Never>?
    @State private var confirmingRemoval = false
    @State private var preview: GitDeletionPreview?
    @State private var errorMessage: String?
    @State private var table = GitBranchTypes()
    /// What the file holds, so opening the page does not write it back.
    @State private var savedTable: GitBranchTypes?
    @State private var tableError: String?

    /// Where `AgentWatchGit` reads the table: `~/Library/Application Support/AgentWatch`.
    private var tableURL: URL? {
        AgentWatchPaths.supportDirectory()?.appendingPathComponent(GitBranchTypes.fileName)
    }

    var body: some View {
        Form {
            GitProtectionProfiles(folders: profiles)
            GitBranchTypesSection(table: $table, error: tableError)
            Section("Remote branch deletion") {
                LabeledContent("Repository") {
                    Button(folder?.path ?? "Choose Folder…") { choosingFolder = true }
                }
                TextField("Branch", text: $branch)
                Button(reading ? "Reading…" : "Preview Confirmation") {
                    guard let folder else { return }
                    load(folder: folder, branch: branch)
                }
                .disabled(folder == nil || branch.isEmpty)
            }
            .disabled(reading)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let preview {
                Section("Confirmation for this branch") {
                    Text(summary(of: preview))
                    switch preview {
                    case .builtIn:
                        Text("This branch has built-in protection.")
                    case .projectRule:
                        Text("This repository lists the branch as protected.")
                        Button("Remove Project Rule…") { confirmingRemoval = true }
                    case .includedRule:
                        Text("This rule comes from an included Git configuration file.")
                    case .dependsOnRemote:
                        Button("Require Repository Name") {
                            if let folder { load(folder: folder, branch: branch, protected: true) }
                        }
                    }
                }
                .disabled(reading)
            }
            Footnote(
                "Edits apply to this repository and its linked working folders. The Git protection tool also checks the remote’s default branch when deletion is requested."
            )
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { selection in
            switch selection {
            case .success(let url):
                folder = url
                clearResult()
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
            }
        }
        .confirmationDialog("Remove this project’s rule for “\(branch)”?", isPresented: $confirmingRemoval) {
            Button("Remove Project Rule", role: .destructive) {
                if let folder { load(folder: folder, branch: branch, protected: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "An included rule, built-in protection, or the remote’s default branch can still require the repository name."
            )
        }
        .onChange(of: branch) { clearResult() }
        .onAppear(perform: loadTable)
        .onChange(of: table) { saveTable() }
        .onDisappear {
            previewTask?.cancel()
            previewTask = nil
            reading = false
        }
    }

    private func summary(of preview: GitDeletionPreview) -> String {
        let (level, type) = preview.deletionLevel(in: table, branch: branch)
        let source = type.map { " (branch type “\($0)”)" } ?? ""
        let text: String
        switch level {
        case .forbid: return "Deletion is refused without a window\(source). Run it from a terminal."
        case .name: return "Confirm deletion, then enter the repository name\(source)."
        case .click: text = "Confirm deletion once\(source)."
        case .none: text = "No window: the agent’s deletion goes through\(source)."
        }
        return text + " If this is the remote’s default branch, also confirm and enter the repository name."
    }

    private func loadTable() {
        guard savedTable == nil, let url = tableURL else { return }
        do {
            table = try GitBranchTypes.load(from: url)
            savedTable = table
        } catch {
            savedTable = GitBranchTypes()
            tableError =
                "\(url.path) could not be read (\(error.localizedDescription)). Until it is fixed, branches keep the checks they had without types; editing the table here replaces the file."
        }
    }

    private func saveTable() {
        guard let savedTable, savedTable != table, let url = tableURL else { return }
        do {
            try table.save(to: url)
            self.savedTable = table
            tableError = nil
        } catch {
            tableError = "The branch types could not be saved: \(error.localizedDescription)"
        }
    }

    private func clearResult() {
        preview = nil
        errorMessage = nil
    }

    private func load(folder: URL, branch: String, protected: Bool? = nil) {
        clearResult()
        reading = true
        let worker = Task.detached(priority: .userInitiated) {
            if let protected {
                return try GitDeletionPreview.setProjectRule(in: folder, branch: branch, protected: protected)
            }
            return try GitDeletionPreview.read(in: folder, branch: branch)
        }
        previewTask = Task {
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                // A confirmed edit can finish after the settings page closes.
                if protected == nil { worker.cancel() }
            }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): preview = value
            case .failure(let error): errorMessage = error.localizedDescription
            }
            reading = false
            previewTask = nil
        }
    }
}
