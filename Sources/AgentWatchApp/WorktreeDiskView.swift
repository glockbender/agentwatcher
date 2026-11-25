import AgentWatchLookup
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorktreeDiskView: View {
    let activeFolders: @MainActor () async -> WorktreeSessionReading?

    @State private var selectedFolder: URL?
    @State private var choosingFolder = false
    @State private var progress: String?
    @State private var report: WorktreeDiskReport?
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var pending: WorktreeBuildFolder?

    var body: some View {
        Form {
            Section {
                LabeledContent("Repository") {
                    Button(selectedFolder?.path ?? "Choose Folder…") { choosingFolder = true }
                }
                HStack {
                    Button("Scan Working Copies") {
                        notice = nil
                        scan()
                    }
                    .disabled(selectedFolder == nil)
                    if let progress {
                        ProgressView().controlSize(.small)
                        Text(progress).foregroundStyle(.secondary)
                    }
                }
            }.disabled(progress != nil)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
            if let notice { Label(notice, systemImage: "checkmark.circle") }
            if let report {
                Section("Working copies by size") {
                    LabeledContent("Known build and cache folders", value: bytes(report.measuredBytes))
                    Text(
                        "Allocated disk space on this volume. Unknown sizes are excluded. Shared blocks can count toward more than one copy."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    ForEach(report.worktrees) { entry in
                        DisclosureGroup {
                            worktree(entry)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.branch ?? entry.folder.lastPathComponent).font(.headline)
                                    Text(entry.folder.path).font(.caption).foregroundStyle(.secondary)
                                    if entry.folders.contains(where: { $0.cleanup?.candidate != nil }) {
                                        let eligible = entry.folders.filter { $0.cleanup?.candidate != nil }
                                        let size = eligible.compactMap(\.allocatedBytes).reduce(0, +)
                                        Label("\(bytes(size)) in eligible caches", systemImage: "trash")
                                            .font(.caption)
                                    } else if let reason = entry.concerns.first {
                                        Label(reason, systemImage: "exclamationmark.triangle")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(entry.allocatedBytes.map(bytes) ?? "Size unknown").monospacedDigit()
                            }
                        }
                    }
                }
                .disabled(progress != nil)
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder):
                selectedFolder = folder
                report = nil
                errorMessage = nil
                notice = nil
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
            }
        }
        .alert(
            "Move this cache to Trash?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ), presenting: pending
        ) { build in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { moveToTrash(build) }
        } message: { build in
            Text(
                "\(build.folder.path)\n\n\(build.allocatedBytes.map(bytes) ?? "Size unknown"). The next build may take longer. The space stays in use until you empty the Trash."
            )
        }
    }

    @ViewBuilder
    private func worktree(_ entry: WorktreeDiskEntry) -> some View {
        LabeledContent("Owner", value: entry.owner ?? "Unknown")
            .help(entry.ownerEvidence ?? "No unambiguous ownership marker.")
        if let changes = entry.changes {
            let facts = [
                changes.hasStagedChanges ? "staged changes" : nil,
                changes.hasTrackedEdits ? "edited tracked files" : nil,
                changes.hasUntrackedFiles ? "untracked files" : nil,
            ].compactMap { $0 }
            LabeledContent(
                "Local work", value: facts.isEmpty ? "No pending Git changes" : facts.joined(separator: ", "))
        } else {
            LabeledContent("Local work", value: "Unknown")
        }
        if let history = entry.remoteHistory { Text(history).font(.callout) }
        ForEach(entry.concerns, id: \.self) { concern in
            Label(concern, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
        folderActions(entry.folder)
        if entry.folders.isEmpty {
            Text("No build or cache folders listed.").foregroundStyle(.secondary)
        }
        ForEach(entry.folders) { build in
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent(build.folder.lastPathComponent, value: build.allocatedBytes.map(bytes) ?? "Size unknown")
                    .font(.headline)
                Text(build.evidence)
                if let reason = build.cleanup?.reason ?? build.concern {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    if build.cleanup?.candidate != nil {
                        Button("Move Cache to Trash…") { pending = build }
                    }
                    folderActions(build.folder)
                }
            }.padding(.vertical, 4)
        }
    }

    private func folderActions(_ folder: URL) -> some View {
        HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder.path, forType: .string)
            }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func scan() {
        guard let selectedFolder, progress == nil else { return }
        progress = "Scanning…"
        errorMessage = nil
        Task {
            await readReport(in: selectedFolder)
            progress = nil
        }
    }

    private func readReport(in folder: URL) async {
        let active = await activeFolders()?.folders
        do {
            report = try await Task.detached(priority: .utility) {
                try WorktreeDiskScanner.scan(in: folder, activeFolders: active)
            }.value
        } catch {
            report = nil
            errorMessage = error.localizedDescription
        }
    }

    private func moveToTrash(_ build: WorktreeBuildFolder) {
        guard let candidate = build.cleanup?.candidate, let selectedFolder, progress == nil else { return }
        progress = "Checking the cache…"
        errorMessage = nil
        notice = nil
        Task {
            if let active = await activeFolders() {
                do {
                    let folders = active.folders
                    let verified = try await Task.detached(priority: .userInitiated) {
                        try WorktreeCacheCleanup.verifiedTrashURL(candidate, activeFolders: folders)
                    }.value
                    if active.isCurrent() {
                        try FileManager.default.trashItem(at: verified, resultingItemURL: nil)
                        notice = "Moved \(build.folder.path) to Trash."
                    } else {
                        errorMessage = "Session activity changed during the check. The cache was kept."
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                errorMessage = "Could not locate all open sessions. The cache was kept."
            }
            progress = "Refreshing…"
            await readReport(in: selectedFolder)
            progress = nil
        }
    }
}
