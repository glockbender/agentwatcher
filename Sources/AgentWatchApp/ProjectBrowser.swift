import AgentWatchCore
import AgentWatchLookup
import AppKit
import SwiftUI

struct ProjectBrowserEntry: Identifiable, Equatable, Sendable {
    var session: SessionSnapshot
    let copy: GitWorkingCopy?
    var id: String { session.id }
}

enum ProjectBrowserFilter: String, CaseIterable {
    case all = "All"
    case working = "Working"
    case waiting = "Waiting for you"
    case quiet = "No recent activity"

    func includes(_ session: SessionSnapshot, now: Date) -> Bool {
        switch self {
        case .all: true
        case .working: session.phase.claimsWork
        // The same test as the waiting beacon's list, so a Codex question counts in both.
        case .waiting: session.needsUserReply
        case .quiet: SessionFreshnessEvaluator.evaluate(session, now: now) == .noRecentActivity
        }
    }
}

enum ProjectBrowserScope: Hashable {
    case recent, project(URL), unknown, profiles
}

enum WatchDestination: String, CaseIterable {
    case projects, waiting, settings

    init?(url: URL, development: Bool) {
        let prefix = development ? "agentwatch-dev://" : "agentwatch://"
        guard let destination = Self.allCases.first(where: { url.absoluteString == prefix + $0.rawValue })
        else { return nil }
        self = destination
    }
}

enum ProjectBrowserCatalog {
    static let recentLimit = 20

    static func visible(
        _ entries: [ProjectBrowserEntry], scope: ProjectBrowserScope, filter: ProjectBrowserFilter,
        search: String, now: Date
    ) -> [ProjectBrowserEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = entries.filter { entry in
            let row = entry.session
            switch scope {
            case .project(let id) where entry.copy?.commonDirectory != id: return false
            case .unknown where entry.copy != nil: return false
            default: break
            }
            let fields = [
                row.title, row.projectName, row.gitBranch, row.source.rawValue, entry.copy?.root.path,
                entry.copy?.projectURL.path,
            ]
            return filter.includes(row, now: now)
                && (needle.isEmpty || fields.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(needle) })
        }.sorted { left, right in
            let lhs = left.session
            let rhs = right.session
            if (lhs.phase == .completed) != (rhs.phase == .completed) { return lhs.phase != .completed }
            if lhs.lastObservedAt != rhs.lastObservedAt { return lhs.lastObservedAt > rhs.lastObservedAt }
            return lhs.id < rhs.id
        }
        return scope == .recent ? Array(matched.prefix(recentLimit)) : matched
    }
}

@MainActor
final class ProjectBrowserModel: ObservableObject {
    @Published var scope: ProjectBrowserScope? = .recent
    @Published var filter = ProjectBrowserFilter.all
    @Published var search = ""

    func navigate(to scope: ProjectBrowserScope) {
        self.scope = scope
        filter = .all
        search = ""
        message = nil
    }

    @Published private(set) var entries: [ProjectBrowserEntry] = []
    @Published private(set) var reading = false
    @Published private(set) var readsTranscripts = false
    @Published var message: String?
    private var snapshots: [SessionSnapshot] = []
    @Published private(set) var folders: AgentFolders?
    @Published private(set) var profileSessions: [SessionSnapshot] = []
    @Published private(set) var claudeUsage: [String: AgentUsageLimits] = [:]
    private var job: Task<Void, Never>?
    private var generation = 0

    /// Live phase/title changes are cheap. Only new identities, a changed host or an explicit
    /// refresh require another disk lookup; no monitor is started for a hidden window.
    func update(
        _ sessions: [SessionSnapshot], folders: AgentFolders, claudeUsage: [String: AgentUsageLimits],
        readsTranscripts: Bool, refresh: Bool = false
    ) {
        profileSessions = sessions.filter { $0.source == .codex && $0.phase != .sessionClosed }
        if self.claudeUsage != claudeUsage { self.claudeUsage = claudeUsage }
        let candidates = sessions.filter(ProjectSessionLookup.isCandidate).sorted { $0.id < $1.id }
        let sameIdentities = snapshots.elementsEqual(candidates) {
            $0.id == $1.id && $0.transcriptLabel == $1.transcriptLabel && $0.agentProcessID == $1.agentProcessID
                && $0.projectName == $1.projectName && $0.gitBranch == $1.gitBranch
        }
        let sourceChanged = self.readsTranscripts != readsTranscripts || self.folders != folders
        let reread = refresh || sourceChanged || !sameIdentities
        if sourceChanged {
            self.readsTranscripts = readsTranscripts
            entries = []
        }
        snapshots = candidates
        if self.folders != folders { self.folders = folders }
        let latest = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        entries = entries.compactMap { entry in
            latest[entry.id].map { ProjectBrowserEntry(session: $0, copy: entry.copy) }
        }
        guard reread else { return }
        generation += 1
        let expected = generation
        job?.cancel()
        reading = !candidates.isEmpty
        guard !candidates.isEmpty else { return }
        let worker = Task.detached(priority: .utility) {
            let lookup = ProjectSessionLookup(folders: folders, transcriptFiles: readsTranscripts ? .live : nil)
            let locations = lookup.locations(of: candidates)
            var copies: [URL: GitWorkingCopy?] = [:]
            var found: [ProjectBrowserEntry] = []
            for session in candidates {
                guard !Task.isCancelled else { break }
                guard let location = locations[session.id] else { continue }
                var copy: GitWorkingCopy?
                if let directory = location.directory {
                    if let cached = copies[directory] {
                        copy = cached
                    } else {
                        copy = GitWorkingCopy.read(in: directory)
                        copies.updateValue(copy, forKey: directory)
                    }
                }
                found.append(ProjectBrowserEntry(session: session, copy: copy))
            }
            return found
        }
        job = Task {
            let found = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, expected == generation else { return }
            let latest = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
            entries = found.compactMap { entry in
                latest[entry.id].map { ProjectBrowserEntry(session: $0, copy: entry.copy) }
            }
            reading = false
        }
    }

    func stop() {
        generation += 1
        job?.cancel()
        job = nil
        entries = []
        snapshots = []
        folders = nil
        profileSessions = []
        claudeUsage = [:]
        reading = false
        readsTranscripts = false
        message = nil
    }

    func open(_ entry: ProjectBrowserEntry) {
        guard let folders, let snapshot = snapshots.first(where: { $0.id == entry.id }) else { return }
        let expected = generation
        Task {
            // Archive, closure or PID reuse between presentation and click invalidates the link.
            let location = await Task.detached(priority: .userInitiated) {
                ProjectSessionLookup(folders: folders, transcriptFiles: nil).location(of: snapshot)
            }.value
            guard generation == expected else { return }
            guard let location else {
                entries.removeAll { $0.id == entry.id }
                message = "This chat is no longer available in its desktop app."
                return
            }
            if !NSWorkspace.shared.open(location.link) { message = "macOS could not open this chat." }
        }
    }
}

@MainActor
final class ProjectBrowserWindow: NSWindowController, NSWindowDelegate {
    let model = ProjectBrowserModel()
    let refresh: () -> Void

    init(openSession: @escaping (String) -> SessionClick, settings: @escaping () -> Void, refresh: @escaping () -> Void)
    {
        self.refresh = refresh
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Projects & Recent"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 370)
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: ProjectBrowserView(model: model, refresh: refresh, openSession: openSession, settings: settings))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) { model.stop() }
}

private struct ProjectBrowserView: View {
    @ObservedObject var model: ProjectBrowserModel
    let refresh: () -> Void
    let openSession: (String) -> SessionClick
    let settings: () -> Void

    private var projects: [GitWorkingCopy] {
        var seen = Set<URL>()
        return model.entries.compactMap(\.copy).filter { seen.insert($0.commonDirectory).inserted }
            .sorted { $0.projectURL.path < $1.projectURL.path }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.scope) {
                Label("Recent", systemImage: "clock").tag(ProjectBrowserScope.recent)
                Label("Usage profiles", systemImage: "chart.bar").tag(ProjectBrowserScope.profiles)
                Section("Projects") {
                    ForEach(projects, id: \.commonDirectory) { copy in
                        VStack(alignment: .leading) {
                            Text(copy.projectURL.lastPathComponent)
                            Text(copy.projectURL.path).lineLimit(1).truncationMode(.middle).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .help(copy.projectURL.path).tag(ProjectBrowserScope.project(copy.commonDirectory))
                    }
                    if model.entries.contains(where: { $0.copy == nil }) {
                        Label("Unknown project", systemImage: "questionmark.folder").tag(ProjectBrowserScope.unknown)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 205)
        } detail: {
            if model.scope == .profiles, let folders = model.folders {
                UsageProfilesView(
                    folders: folders, claude: model.claudeUsage, sessions: model.profileSessions,
                    readsTranscripts: model.readsTranscripts)
            } else {
                chats
            }
        }
        .toolbar {
            Button(action: settings) { Label("Settings", systemImage: "gearshape") }
        }
    }

    private var chats: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search chats, projects or branches", text: $model.search)
                Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
            }
            Picker("Filter", selection: $model.filter) {
                ForEach(ProjectBrowserFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if model.entries.contains(where: { $0.session.phase.claimsWork }) {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    chatList(now: context.date)
                }
            } else {
                chatList(now: .now)
            }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            Text(
                "Observed desktop chats with a verified link. Recent shows up to \(ProjectBrowserCatalog.recentLimit). Closed chats are excluded."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }

    @ViewBuilder
    private func chatList(now: Date) -> some View {
        let rows = ProjectBrowserCatalog.visible(
            model.entries, scope: model.scope ?? .recent, filter: model.filter, search: model.search, now: now)
        if rows.isEmpty {
            ContentUnavailableView(
                model.reading ? "Reading projects…" : "No matching chats", systemImage: "bubble.left.and.bubble.right")
        } else {
            List(rows) { entry in
                Button {
                    model.open(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.session.title ?? "Untitled chat").font(.headline)
                            Spacer()
                            Text(entry.session.lastObservedAt, style: .relative).font(.caption)
                                .help(entry.session.lastObservedAt.formatted())
                        }
                        Text(
                            [
                                entry.session.source == .claude ? "Claude" : "Codex", entry.session.phase.settingsName,
                                entry.session.activities.max(by: { $0.startedAt < $1.startedAt })?.kind.rawValue,
                                entry.session.gitBranch, entry.copy?.root.path ?? "Unknown project",
                            ].compactMap { $0 }.joined(separator: " · ")
                        )
                        .lineLimit(2).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}
