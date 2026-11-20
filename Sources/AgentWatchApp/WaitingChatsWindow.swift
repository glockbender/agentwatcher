import AgentWatchCore
import AppKit
import SwiftUI

@MainActor
final class WaitingChatsModel: ObservableObject {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String

        init(_ session: SessionSnapshot) {
            id = session.id
            title = session.title ?? session.projectName ?? "Chat \(session.id.suffix(8))"
            let agent = session.source == .codex ? "Codex" : "Claude"
            detail = [agent, session.projectName == title ? nil : session.projectName].compactMap { $0 }.joined(
                separator: " · ")
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var unavailableID: String?
    private let focus: (String) -> SessionClick

    init(focus: @escaping (String) -> SessionClick) {
        self.focus = focus
    }

    func update(_ sessions: [SessionSnapshot]) {
        let waiting = sessions.filter { $0.needsUserReply && !$0.isHeadlessRun }
            .sorted { lhs, rhs in
                lhs.lastObservedAt == rhs.lastObservedAt ? lhs.id < rhs.id : lhs.lastObservedAt > rhs.lastObservedAt
            }.map(Row.init)
        guard waiting != rows else { return }
        rows = waiting
        if let unavailableID, !waiting.contains(where: { $0.id == unavailableID }) { self.unavailableID = nil }
    }

    func open(_ id: String) -> Bool {
        guard rows.contains(where: { $0.id == id }) else { return false }
        let opened = focus(id) == .raised
        unavailableID = opened ? nil : id
        return opened
    }
}

@MainActor
final class WaitingChatsWindow: NSWindowController {
    init(model: WaitingChatsModel) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Chats waiting for your reply"
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 280, height: 120)
        panel.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications, .fullScreenAuxiliary]
        panel.level = .floating
        super.init(window: panel)
        panel.contentView = NSHostingView(
            rootView: WaitingChatsView(model: model) { [weak panel] id in
                if model.open(id) { panel?.orderOut(nil) }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        guard let window else { return }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
            !window.isVisible || window.screen != screen
        {
            let area = screen.visibleFrame
            window.setFrameOrigin(
                NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private struct WaitingChatsView: View {
    @ObservedObject var model: WaitingChatsModel
    let open: (String) -> Void

    var body: some View {
        if model.rows.isEmpty {
            Text("All caught up. No chats are waiting for a reply.")
                .foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.rows) { row in
                Button {
                    open(row.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.headline).lineLimit(2)
                            Text(row.detail).foregroundStyle(.secondary)
                            if model.unavailableID == row.id {
                                Text("Couldn’t open this chat. Open it in its app or try again.").foregroundStyle(
                                    .secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward").accessibilityHidden(true)
                    }
                    .padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
