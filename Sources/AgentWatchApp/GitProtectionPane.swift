import AgentWatchCore
import AgentWatchGit
import SwiftUI
import UniformTypeIdentifiers

struct GitProtectionPane: View {
    let profiles: AgentFolders
    var rulesURL = AgentWatchPaths.supportDirectory()?.appendingPathComponent(GitProtectionRules.fileName)

    private enum Scope: Hashable { case all, repository }
    private enum FolderUse { case rules, preview }
    private struct PreviewRequest: Equatable {
        let repository: GitProtectionRepository?
        let branch: String
    }
    private struct EditorSelection: Identifiable {
        let id = UUID()
        let operation: GitBranchOperation
        let repository: GitProtectionRepository?
        let rule: GitBranchType?
        let index: Int?
        let count: Int
    }

    @State private var rules: GitProtectionRules?
    @State private var settingsError: String?
    @State private var confirmsDisable = false
    @State private var operation = GitBranchOperation.delete
    @State private var scope = Scope.all
    @State private var rulesRepository: GitProtectionRepository?
    @State private var previewRepository: GitProtectionRepository?
    @State private var folderError: String?
    @State private var choosingFolder = false
    @State private var folderUse = FolderUse.rules
    @State private var readingFolder = false
    @State private var branch = ""
    @State private var preview: GitDeletionPreview?
    @State private var previewError: String?
    @State private var readingPreview = false
    @State private var confirmsLegacyRemoval = false
    @State private var editor: EditorSelection?

    private var enabled: Bool { rules?.enabled ?? true }
    private var activeRepository: GitProtectionRepository? { scope == .repository ? rulesRepository : nil }
    private var currentRules: [GitBranchType] {
        if scope == .repository {
            guard let key = activeRepository?.key else { return [] }
            return rules?.repositories[key]?[operation] ?? []
        }
        return rules?.global[operation] ?? []
    }
    private var canAddRule: Bool {
        rules != nil && operation != .push && (scope == .all || activeRepository != nil)
    }

    private var previewRequest: PreviewRequest { PreviewRequest(repository: previewRepository, branch: branch) }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                protectionSwitch
                GitProtectionProfiles(folders: profiles)
                branchRules { withAnimation { proxy.scrollTo("branch-preview", anchor: .top) } }
                branchPreview.id("branch-preview")
            }
        }
        .task { loadRules() }
        .task(id: previewRequest) { await readPreview(previewRequest) }
        .onChange(of: operation) { if operation == .push { scope = .all } }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder], onCompletion: acceptFolder)
        .sheet(item: $editor) { selection in
            GitProtectionRuleEditor(
                operation: selection.operation,
                repository: selection.repository,
                rule: selection.rule,
                canMoveEarlier: (selection.index ?? 0) > 0,
                canMoveLater: selection.index.map { $0 + 1 < selection.count } ?? false,
                change: { try edit(selection, change: $0) }
            )
        }
        .alert("Turn off Git Protection?", isPresented: $confirmsDisable) {
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("Turn Off Protection", role: .destructive) { setEnabled(false) }
        } message: {
            Text(
                "Agent Watch will stop checking Git commands in all connected profiles. Agents can push to protected branches, rewrite history, or delete remote branches without an Agent Watch confirmation. Your hooks and rules are saved."
            )
        }
        .alert("Remove this repository’s existing protection for this branch?", isPresented: $confirmsLegacyRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Rule", role: .destructive) { removeLegacyRule() }
        } message: {
            Text("Other rules and the remote’s default branch can still require the repository name.")
        }
    }

    private var protectionSwitch: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { enabled },
                    set: { value in
                        if value { setEnabled(true) } else { confirmsDisable = true }
                    })
            ) {
                Label {
                    Heading(
                        title: "Protect Git commands",
                        hint: enabled
                            ? "Checks Git commands from connected agent profiles."
                            : "Protection is off for all profiles. Hooks and rules are saved.")
                } icon: {
                    Image(systemName: enabled ? "checkmark.shield" : "shield.slash")
                        .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(rules == nil)
            if let settingsError {
                Text(settingsError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func branchRules(openPreview: @escaping () -> Void) -> some View {
        Section {
            Picker("Git operation", selection: $operation) {
                ForEach(GitBranchOperation.allCases) { operation in
                    Text(operation.title).tag(operation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if operation != .push {
                Picker("Rule scope", selection: $scope) {
                    Text("All repositories").tag(Scope.all)
                    Text("One repository…").tag(Scope.repository)
                }
                if scope == .repository {
                    LabeledContent("Repository") {
                        repositoryButton(rulesRepository, use: .rules)
                    }
                    if let folderError, folderUse == .rules { errorText(folderError) }
                }
            }
            LabeledContent {
                Text(operation.defaultLevel.title)
            } label: {
                Heading(title: scope == .all ? "Default" : "Inherited default", hint: "Branches with no matching rule")
            }
            LabeledContent {
                Text(GitCheckLevel.name.title)
            } label: {
                Heading(
                    title: "Protected branches",
                    hint: operation == .push
                        ? "main and master"
                        : "main, master, the remote’s default branch, and branches protected in Git")
            }
            ForEach(currentRules) { rule in
                let patterns = rule.patterns.joined(separator: " ")
                HStack {
                    Text(patterns)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                        .help(patterns)
                    Spacer()
                    Text(rule.level.title)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Button("Edit…") { openEditor(for: rule) }
                        .accessibilityLabel("Edit rule for \(patterns)")
                        .disabled(rules == nil)
                }
            }
            if operation != .push {
                Button {
                    openEditor()
                } label: {
                    Label("Add \(operation.ruleTitle)…", systemImage: "plus")
                }
                .disabled(!canAddRule)
            }
        } header: {
            HStack {
                Text("Branch rules")
                Spacer()
                Button("Preview a Branch", systemImage: "arrow.down", action: openPreview)
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
            }
        } footer: {
            Footnote(
                operation == .push
                    ? "These built-in checks apply to ordinary pushes. Git can also require confirmation when it cannot determine the destination from the command."
                    : scope == .all
                        ? "The first matching rule applies. Protected branches always require at least the check shown above."
                        : "The first matching repository rule can make the global check stricter. Linked working copies use the same rules."
            )
        }
    }

    private var branchPreview: some View {
        Section("Preview a branch") {
            LabeledContent("Repository") {
                repositoryButton(previewRepository, use: .preview)
            }
            TextField("Branch", text: $branch, prompt: Text("release/2026.11"))
            if !enabled {
                Heading(title: "Protection is off", hint: "Agent Watch skips this check while Git Protection is off.")
            } else if let folderError, folderUse == .preview {
                errorText(folderError)
            } else if let previewError {
                errorText(previewError)
            } else if readingPreview {
                ProgressView().controlSize(.small)
            } else if let preview {
                let result = previewResult(preview)
                Heading(title: result.level.title, hint: result.reason)
                if operation != .push && preview == .projectRule {
                    Button("Remove Repository’s Existing Rule…", role: .destructive) { confirmsLegacyRemoval = true }
                }
            } else {
                Footnote("Choose a repository and enter a branch name to preview \(operation.title).")
            }
        }
    }

    private func previewResult(_ evidence: GitDeletionPreview) -> (level: GitCheckLevel, reason: String) {
        let choice = (rules ?? GitProtectionRules()).level(
            for: operation, branch: branch, repository: previewRepository?.key)
        let protected = evidence == .builtIn || (operation != .push && evidence != .dependsOnRemote)
        if protected && choice.level <= .name {
            switch evidence {
            case .builtIn: return (.name, "Built-in protection for \(branch).")
            case .projectRule: return (.name, "This branch is protected in the repository’s Git configuration.")
            case .includedRule: return (.name, "This branch is protected in an included Git configuration file.")
            case .dependsOnRemote: break
            }
        }
        var reason = choice.source.map { "Matches rule “\($0)”." } ?? "Uses the default for \(operation.title)."
        if operation != .push && choice.level < .name {
            reason += " If this is the remote’s default branch, the repository name is also required."
        }
        return (choice.level, reason)
    }

    private func repositoryButton(_ repository: GitProtectionRepository?, use: FolderUse) -> some View {
        Button(repository?.folder.lastPathComponent ?? "Choose Folder…") {
            folderUse = use
            choosingFolder = true
        }
        .help(repository?.folder.path ?? "Choose a folder in a Git repository")
        .disabled(readingFolder)
    }

    private func errorText(_ error: String) -> some View {
        Text(error).font(.caption).foregroundStyle(.red)
    }

    private func acceptFolder(_ selection: Result<URL, Error>) {
        switch selection {
        case .success(let folder):
            folderError = nil
            readingFolder = true
            let purpose = folderUse
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try GitProtectionRepository(folder: folder) }
                }.value
                readingFolder = false
                switch result {
                case .success(let repository):
                    if purpose == .rules { rulesRepository = repository }
                    previewRepository = repository
                case .failure(let error): folderError = error.localizedDescription
                }
            }
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { folderError = error.localizedDescription }
        }
    }

    private func readPreview(_ request: PreviewRequest) async {
        preview = nil
        previewError = nil
        readingPreview = false
        guard let repository = request.repository, !request.branch.isEmpty else { return }
        readingPreview = true
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch { return }
        let worker = Task.detached(priority: .userInitiated) {
            try GitDeletionPreview.read(in: repository.folder, branch: request.branch)
        }
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        readingPreview = false
        switch result {
        case .success(let value): preview = value
        case .failure(let error): previewError = error.localizedDescription
        }
    }

    private func removeLegacyRule() {
        guard let repository = previewRepository else { return }
        let request = previewRequest
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try GitDeletionPreview.setProjectRule(
                        in: repository.folder, branch: request.branch, protected: false)
                }
            }.value
            guard previewRequest == request else { return }
            switch result {
            case .success(let value): preview = value
            case .failure(let error): previewError = error.localizedDescription
            }
        }
    }

    private func loadRules() {
        do {
            rules = try GitProtectionRules.load(from: settingsPath())
            settingsError = nil
        } catch {
            settingsError = "Could not read Git protection rules. Built-in checks apply. \(error.localizedDescription)"
        }
    }

    private func settingsPath() throws -> URL {
        guard let rulesURL else { throw SettingsError.missingDirectory }
        return rulesURL
    }

    private func save(_ updated: GitProtectionRules) throws {
        try updated.save(to: settingsPath())
        rules = updated
        settingsError = nil
    }

    private func setEnabled(_ value: Bool) {
        guard var updated = rules else { return }
        updated.enabled = value
        do { try save(updated) } catch {
            settingsError = "Could not change Git Protection. \(error.localizedDescription)"
        }
    }

    private func openEditor(for rule: GitBranchType? = nil) {
        editor = EditorSelection(
            operation: operation, repository: activeRepository, rule: rule,
            index: rule.flatMap { rule in currentRules.firstIndex { $0.id == rule.id } }, count: currentRules.count)
    }

    private func edit(_ selection: EditorSelection, change: GitProtectionRuleEditor.Change) throws {
        guard var updated = rules else { throw SettingsError.missingDirectory }
        let key = selection.repository?.key
        var scoped = key.map { updated.repositories[$0] ?? GitProtectionRules.Rules() } ?? updated.global
        var list = scoped[selection.operation]
        switch change {
        case .save(let rule):
            if let index = selection.index { list[index] = rule } else { list.insert(rule, at: 0) }
        case .move(let offset):
            if let index = selection.index { list.swapAt(index, index + offset) }
        case .remove:
            if let index = selection.index { list.remove(at: index) }
        }
        scoped[selection.operation] = list
        if let key {
            updated.repositories[key] = scoped.forcePush.isEmpty && scoped.delete.isEmpty ? nil : scoped
        } else {
            updated.global = scoped
        }
        try save(updated)
    }

    private enum SettingsError: LocalizedError {
        case missingDirectory
        var errorDescription: String? { "Agent Watch could not locate its Application Support folder." }
    }
}
