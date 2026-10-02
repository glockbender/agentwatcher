import AgentWatchCore
import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case widget, rows, order, appearance, theme, timing, themes, menuBar, general, tooling, diagnostics

    var id: String { rawValue }

    /// The sidebar entry a page sits under; a sub-page highlights its parent.
    var parent: SettingsPage {
        switch self {
        case .rows, .order: .widget
        case .theme, .timing, .themes: .appearance
        default: self
        }
    }

    static let sidebar: [SettingsPage] = [.widget, .appearance, .menuBar, .general, .tooling, .diagnostics]

    var title: String {
        switch self {
        case .widget: "Widget"
        case .rows: "Rows"
        case .order: "Order"
        case .appearance: "Appearance"
        case .theme: "Edit Theme"
        case .timing: "Timing"
        case .themes: "Your Themes"
        case .menuBar: "Menu Bar"
        case .general: "General"
        case .tooling: "Tooling"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .widget, .rows, .order: "rectangle.split.3x1"
        case .appearance, .theme, .timing, .themes: "paintpalette"
        case .menuBar: "menubar.rectangle"
        case .general: "gearshape"
        case .tooling: "wrench.and.screwdriver"
        case .diagnostics: "stethoscope"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var selection: Binding<SettingsPage?> {
        Binding(get: { model.page.parent }, set: { $0.map(model.go) })
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.sidebar, selection: selection) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch model.page {
                case .widget: WidgetPane(model: model)
                case .rows: RowPane(model: model)
                case .order: OrderPane(model: model)
                case .appearance: AppearancePane(model: model)
                case .theme: ThemeEditorPane(model: model)
                case .timing: TimingPane(model: model)
                case .themes: ThemesPane(model: model)
                case .menuBar: MenuBarPane(model: model)
                case .general: GeneralPane(model: model)
                case .tooling: ToolingPane(model: model)
                case .diagnostics: DiagnosticsPane(model: model)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(model.page.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!model.canGoBack)
                    .help("Back")
                    Button {
                        model.goForward()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!model.canGoForward)
                    .help("Forward")
                }
            }
        }
    }
}

/// A row that opens a page, as System Settings draws one.
struct PageLink: View {
    let title: String
    let detail: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        // A form's footer sets its wrapped lines to the trailing edge; a note reads from the left.
        Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Buttons under a section, outside its box, as System Settings places them.
struct SectionButtons<Buttons: View>: View {
    var note: String?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let note {
                Footnote(note)
            }
            HStack {
                Spacer()
                buttons
            }
        }
    }
}

/// A section's title with one line under it saying how to use what follows.
struct Heading: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(hint).font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
        }
    }
}

// MARK: - Reordering

/// Where a dragged item lands: in the dropped-on item's place, the rest shifting to make room.
enum Reorder {
    static func moving<Item: Equatable>(_ item: Item, onto target: Item, in items: [Item]) -> [Item] {
        guard item != target, let from = items.firstIndex(of: item), let to = items.firstIndex(of: target) else {
            return items
        }
        var moved = items
        moved.remove(at: from)
        moved.insert(item, at: to)
        return moved
    }
}

/// A reorderable collection the macOS way: a bordered table whose rows are dragged, one line
/// each, as tall as its rows so the form around it does the scrolling.
struct ReorderTable<Item: Hashable, Row: View>: View {
    static var rowHeight: CGFloat { 30 }
    @Binding var items: [Item]
    let moved: ([Item]) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        List {
            ForEach(items, id: \.self) { item in
                row(item).frame(height: Self.rowHeight - 8)
            }
            .onMove { source, destination in
                items.move(fromOffsets: source, toOffset: destination)
                moved(items)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(items.count) * Self.rowHeight + 10)
        .listRowInsets(EdgeInsets())
    }
}
