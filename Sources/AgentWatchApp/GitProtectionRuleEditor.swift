import AgentWatchGit
import SwiftUI

struct GitProtectionRuleEditor: View {
    enum Change {
        case save(GitBranchType)
        case move(Int)
        case remove
    }

    let operation: GitBranchOperation
    let repository: GitProtectionRepository?
    let rule: GitBranchType?
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let change: (Change) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var patterns = ""
    @State private var level = GitCheckLevel.click
    @State private var errorMessage: String?
    @State private var confirmsRemoval = false

    private var patternList: [String] { patterns.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var choices: [GitCheckLevel] { repository == nil ? GitCheckLevel.allCases : [.click, .name, .forbid] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text((rule == nil ? "Add " : "Edit ") + operation.ruleTitle).font(.headline)
                Text("\(repository?.folder.lastPathComponent ?? "All repositories") · \(operation.title)")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Branch pattern")
                    TextField("Branch pattern", text: $patterns, prompt: Text("release/*")).labelsHidden()
                }
                GridRow {
                    Text("Agent action")
                    Picker("Agent action", selection: $level) {
                        ForEach(choices, id: \.self) { level in
                            Text(level.title).tag(level)
                        }
                    }.labelsHidden()
                }
            }
            Text("Use * for any characters, including /. Separate multiple patterns with spaces.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            if rule != nil {
                HStack {
                    Button("Move Earlier") { submit(.move(-1)) }.disabled(!canMoveEarlier)
                    Button("Move Later") { submit(.move(1)) }.disabled(!canMoveLater)
                    Spacer()
                    Button("Remove Rule…", role: .destructive) { confirmsRemoval = true }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(rule == nil ? "Add Rule" : "Save Rule") { saveRule() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(patternList.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            patterns = rule?.patterns.joined(separator: " ") ?? ""
            level = rule?.level ?? (repository == nil ? operation.defaultLevel : .name)
        }
        .alert("Remove this branch rule?", isPresented: $confirmsRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Rule", role: .destructive) { submit(.remove) }
        }
    }

    private func saveRule() {
        let name = patternList.joined(separator: " ")
        var updated = rule ?? GitBranchType(name: name, patterns: [], level: level)
        if let rule, rule.name == rule.patterns.joined(separator: " ") { updated.name = name }
        updated.patterns = patternList
        updated.level = level
        submit(.save(updated))
    }

    private func submit(_ action: Change) {
        do {
            try change(action)
            dismiss()
        } catch {
            errorMessage = "Could not save the rule. \(error.localizedDescription)"
        }
    }
}

extension GitBranchOperation {
    var title: String {
        switch self {
        case .push: "Push"
        case .forcePush: "Force Push"
        case .delete: "Delete Remote Branch"
        }
    }

    var ruleTitle: String {
        switch self {
        case .push: "Push Rule"
        case .forcePush: "Force-Push Rule"
        case .delete: "Deletion Rule"
        }
    }
}

extension GitCheckLevel {
    var title: String {
        switch self {
        case .none: "Allow"
        case .click: "Confirm"
        case .name: "Confirm + type repository name"
        case .forbid: "Block"
        }
    }
}
