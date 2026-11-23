import AgentWatchGit
import SwiftUI

/// The table of branch types and the rows no type can lower.
struct GitBranchTypesSection: View {
    @Binding var table: GitBranchTypes
    let error: String?

    var body: some View {
        Section("Branch types") {
            Footnote(
                "The first type whose pattern matches a branch decides how a force push or a remote deletion of it is checked, in every repository. * matches any characters, / included."
            )
            ForEach($table.types) { $type in
                GitBranchTypeRow(
                    type: $type,
                    canMoveUp: type.id != table.types.first?.id,
                    canMoveDown: type.id != table.types.last?.id,
                    move: { offset in move(type.id, by: offset) },
                    remove: { table.types.removeAll { $0.id == type.id } })
            }
            Button("Add Type") {
                table.types.append(GitBranchType(name: "New type", patterns: [], level: .click))
            }
            if let error { Text(error).foregroundStyle(.red) }
            // Fixed rows stay visible, greyed, with the reason beside them.
            LabeledContent("main, master, the remote’s default branch, tags") {
                Text("At least \(GitCheckLevel.name.title)")
            }
            .foregroundStyle(.secondary)
            LabeledContent("Branches without a type") {
                Text("Delete: \(GitCheckLevel.click.title) · Force push: \(GitCheckLevel.name.title)")
            }
            .foregroundStyle(.secondary)
            Footnote(
                "No type lowers the first row, nor a branch a repository marks with Require Repository Name: an agent can edit any settings file, so these are the checks it cannot remove."
            )
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = table.types.firstIndex(where: { $0.id == id }),
            table.types.indices.contains(index + offset)
        else { return }
        table.types.swapAt(index, index + offset)
    }
}

private struct GitBranchTypeRow: View {
    @Binding var type: GitBranchType
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    // Kept apart from the patterns so a space typed between two of them is not split away.
    @State private var patterns = ""

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Name", text: $type.name)
                Picker("Check", selection: $type.level) {
                    ForEach(GitCheckLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .help("Check this type earlier")
                Button {
                    move(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .help("Check this type later")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .help("Remove this type")
            }
            .buttonStyle(.borderless)
            TextField("Patterns", text: $patterns, prompt: Text("feature/* fix/*"))
            Text(type.level.explanation).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { patterns = type.patterns.joined(separator: " ") }
        .onChange(of: patterns) {
            type.patterns = patterns.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }
}

extension GitCheckLevel {
    var title: String {
        switch self {
        case .none: "No Window"
        case .click: "Click"
        case .name: "Click + Name"
        case .forbid: "Forbid"
        }
    }

    var explanation: String {
        switch self {
        case .none: "The agent’s own force push or deletion goes through without asking."
        case .click: "One confirmation window."
        case .name: "A confirmation, then the repository name typed in."
        case .forbid: "Always refused; run the command from a terminal yourself."
        }
    }
}
