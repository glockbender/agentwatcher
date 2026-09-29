import AgentWatchCore
import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case widget, rows, order, appearance, menuBar, general, tooling, diagnostics

    var id: String { rawValue }

    /// The sidebar entry a page sits under; a sub-page highlights its parent.
    var parent: SettingsPage {
        switch self {
        case .rows, .order: .widget
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
        case .menuBar: "Menu Bar"
        case .general: "General"
        case .tooling: "Tooling"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .widget, .rows, .order: "rectangle.split.3x1"
        case .appearance: "paintpalette"
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

// MARK: - Widget

/// The widget as it will look, and the two things that shape its list: what a row shows, and
/// in which order the rows stand.
struct WidgetPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                SampleRowsView(model: model, revision: model.revision)
                    .frame(height: SampleRowsView.height)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Footnote("The same session at work and finished. Only a finished row has a ×.")
            }
            Section {
                PageLink(title: "Rows", detail: "\(model.layout.parts.filter { $0 != .gap }.count) parts") {
                    model.go(.rows)
                }
                PageLink(title: "Order", detail: model.settings.sessionOrder.settingsTitle) {
                    model.go(.order)
                }
            }
        }
    }
}

/// A row that opens a page, as System Settings draws one.
private struct PageLink: View {
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

private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Buttons under a section, outside its box, as System Settings places them.
private struct SectionButtons<Buttons: View>: View {
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
private struct Heading: View {
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
private struct ReorderTable<Item: Hashable, Row: View>: View {
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

// MARK: - Row

/// The parts, in one list that never reorders itself: switching a part off leaves it where it
/// is, and only a drag moves anything.
struct RowPane: View {
    @ObservedObject var model: SettingsModel
    @State private var listed: [RowPart] = []

    var body: some View {
        let layout = model.layout
        Form {
            Section {
                SampleRowsView(model: model, revision: model.revision)
                    .frame(height: SampleRowsView.height)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                ReorderTable(items: $listed) { listed in
                    model.setLayout(model.layout.changing(parts: RowPartList.parts(from: listed, in: model.layout)))
                } row: { part in
                    PartRow(model: model, part: part, layout: layout)
                }
            } header: {
                Heading(title: "Parts", hint: "Drag a row to reorder. Hover a part to see when it appears.")
            }
            Section {
                Picker("When the widget is narrow, shorten", selection: flexible(layout)) {
                    ForEach(layout.parts.filter(\.canGiveWay), id: \.self) { part in
                        Text(part.settingsName).tag(Optional(part))
                    }
                }
                .disabled(!layout.parts.contains(where: \.canGiveWay))
                Toggle("Keep the × column on every row", isOn: keepsDismissColumn(layout))
            } footer: {
                SectionButtons {
                    Button("Restore Defaults") {
                        model.setLayout(.standard)
                        listed = RowPartList.listed(for: .standard)
                    }
                }
            }
        }
        .onAppear { listed = RowPartList.listed(for: model.layout) }
        .onChange(of: model.revision) {
            if RowPartList.parts(from: listed, in: model.layout) != model.layout.parts {
                listed = RowPartList.listed(for: model.layout)
            }
        }
    }

    private func flexible(_ layout: RowLayout) -> Binding<RowPart?> {
        Binding(
            get: { layout.flexible },
            set: { part in model.setLayout(model.layout.changing(flexible: part)) }
        )
    }

    private func keepsDismissColumn(_ layout: RowLayout) -> Binding<Bool> {
        Binding(
            get: { layout.reservesDismissColumn },
            set: { model.setLayout(model.layout.changing(reservesDismissColumn: $0)) }
        )
    }
}

/// Every part in the order a person arranged them, the ones left out included, and how a
/// switch turns that list back into the row's parts.
enum RowPartList {
    static func listed(for layout: RowLayout) -> [RowPart] {
        layout.parts + RowPart.allCases.filter { !layout.parts.contains($0) }
    }

    /// The row's parts in the list's order: a part switched on takes its place in the list.
    static func parts(from listed: [RowPart], in layout: RowLayout) -> [RowPart] {
        listed.filter(layout.shows)
    }

    static func parts(from listed: [RowPart], in layout: RowLayout, switching part: RowPart, on: Bool) -> [RowPart] {
        listed.filter { $0 == part ? on : layout.shows($0) }
    }

    /// A row has to draw something, so the last part in it stays.
    static func isLast(_ part: RowPart, in layout: RowLayout) -> Bool {
        layout.shows(part) && layout.parts.filter { $0 != .gap }.count == 1
    }
}

private struct PartRow: View {
    @ObservedObject var model: SettingsModel
    let part: RowPart
    let layout: RowLayout

    var body: some View {
        HStack {
            if part == .gap {
                Label("Gap — parts below it sit at the right end", systemImage: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
            } else {
                Toggle(part.settingsName, isOn: shown)
                    .toggleStyle(.checkbox)
                    .disabled(RowPartList.isLast(part, in: layout))
                    .help("\(part.settingsName): \(part.appearsWhen)")
            }
            Spacer()
            options
                .controlSize(.small)
                .disabled(!layout.shows(part))
        }
    }

    @ViewBuilder private var options: some View {
        if part == .counters {
            Menu(RowPartText.counterKindsTitle(layout.counterKinds)) {
                ForEach(ActivityKind.allCases, id: \.self) { kind in
                    Toggle(kind.settingsName, isOn: counts(kind))
                }
            }
            .fixedSize()
        } else if !part.variantTitles.isEmpty {
            Picker(part.settingsName, selection: variant) {
                ForEach(Array(part.variantTitles.enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var shown: Binding<Bool> {
        Binding(
            get: { layout.shows(part) },
            set: { on in
                let listed = RowPartList.listed(for: model.layout)
                model.setLayout(
                    model.layout.changing(
                        parts: RowPartList.parts(from: listed, in: model.layout, switching: part, on: on)))
            }
        )
    }

    private var variant: Binding<Int> {
        Binding(
            get: { RowPartText.variantIndex(of: part, in: layout) },
            set: { model.setLayout(RowPartText.layout(model.layout, choosing: $0, for: part)) }
        )
    }

    private func counts(_ kind: ActivityKind) -> Binding<Bool> {
        Binding(
            get: { layout.counterKinds.contains(kind) },
            set: { on in
                var kinds = model.layout.counterKinds
                if on { kinds.insert(kind) } else { kinds.remove(kind) }
                model.setLayout(model.layout.changing(counterKinds: kinds))
            }
        )
    }
}

enum RowPartText {
    static func counterKindsTitle(_ kinds: Set<ActivityKind>) -> String {
        kinds.count == ActivityKind.allCases.count
            ? "All kinds"
            : "\(kinds.count) of \(ActivityKind.allCases.count) kinds"
    }

    static func variantIndex(of part: RowPart, in layout: RowLayout) -> Int {
        switch part {
        case .name: layout.nameStyle == .title ? 1 : 0
        case .model: layout.modelStyle == .effort ? 1 : 0
        case .context:
            switch layout.contextStyle {
            case .percent: 0
            case .tokens: 1
            case .both: 2
            }
        default: 0
        }
    }

    static func layout(_ layout: RowLayout, choosing index: Int, for part: RowPart) -> RowLayout {
        let contextStyles: [RowLayout.ContextStyle] = [.percent, .tokens, .both]
        return layout.changing(
            nameStyle: part == .name ? (index == 1 ? .title : .fallback) : nil,
            modelStyle: part == .model ? (index == 1 ? .effort : .plain) : nil,
            contextStyle: part == .context ? contextStyles[min(max(index, 0), contextStyles.count - 1)] : nil
        )
    }
}

/// Two real rows, built the way the widget builds them, on the widget's background.
struct SampleRowsView: NSViewRepresentable {
    static let height: CGFloat = 64
    let model: SettingsModel
    let revision: Int

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        stack.pinToEdges(of: holder)
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        guard let stack = holder.subviews.compactMap({ $0 as? NSStackView }).first else { return }
        holder.subviews.filter { $0 !== stack }.forEach { $0.removeFromSuperview() }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let background = model.themes.widgetBackground(on: model.backgroundStore.material)
        let panel = makeBackgroundView(for: background, opacity: model.backgroundStore.opacity)
        panel.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(panel, positioned: .below, relativeTo: stack)
        panel.pinToEdges(of: holder)
        let layout = model.layout
        let working = SampleSession.make(id: "codex:sample", phase: .executing)
        stack.addArrangedSubview(
            row(
                working,
                dismissal: .notOffered(until: working.lastObservedAt.addingTimeInterval(1_800)),
                layout: layout,
                background: background))
        stack.addArrangedSubview(
            row(
                SampleSession.make(id: "codex:sample-finished", phase: .completed), dismissal: .now,
                layout: layout, background: background))
    }

    private func row(
        _ snapshot: SessionSnapshot, dismissal: RowDismissal, layout: RowLayout, background: WidgetBackground
    ) -> HUDSessionRowView {
        let row = HUDSessionRowView(
            snapshot: snapshot,
            now: snapshot.lastObservedAt.addingTimeInterval(4),
            background: background,
            lampScheme: model.themes.look.lampScheme,
            layout: layout,
            onFocus: {},
            dismissal: dismissal,
            onRemove: {}
        )
        row.setFlexibleText(
            layout.flexible.flatMap { rowPartText($0, for: snapshot, layout: layout) }, display: .fullName)
        return row
    }
}

/// One session that has something for every part, so every part can be seen and placed.
enum SampleSession {
    static func make(id: String, phase: SessionPhase) -> SessionSnapshot {
        var sample = SessionSnapshot(
            id: id,
            source: .codex,
            arrivalIndex: 0,
            title: "Port the probe to the new API",
            projectName: "agent-watch",
            gitBranch: "row-format",
            mode: .unknown,
            phase: phase,
            activities: [
                SessionActivity(id: "a", kind: .shell, startedAt: .distantPast),
                SessionActivity(id: "b", kind: .tool, startedAt: .distantPast),
            ],
            lastObservedAt: .distantPast,
            clientKind: .cli
        )
        sample.modelName = "gpt-5-codex"
        sample.reasoningEffort = "high"
        sample.threadKind = .subagent
        sample.threadNickname = "Darwin"
        sample.monitoringFault = .transcriptNotFound
        sample.contextTelemetry = .init(totalInputTokens: 212_000, usedPercentage: 63)
        return sample
    }
}

// MARK: - Order

struct OrderPane: View {
    @ObservedObject var model: SettingsModel
    @State private var blocks: [SessionBlock] = []

    var body: some View {
        let order = model.settings.sessionOrder
        Form {
            Section {
                OrderPreview(model: model, revision: model.revision)
                    .frame(height: OrderPreview.height)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Footnote(OrderPreview.caption(for: order))
            }
            Section("Order rows by") {
                Picker("Order rows by", selection: sessionOrder) {
                    ForEach(SessionOrder.allCases, id: \.self) { order in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(order.settingsTitle)
                            Text(order.settingsExplanation).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(order)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Section {
                ReorderTable(items: $blocks) { blocks in
                    model.update { model.settings.setSessionBlockOrder(blocks) }
                } row: { block in
                    HStack {
                        Text(block.settingsTitle)
                        Spacer()
                        Text(block.settingsExplanation)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(block.settingsExplanation)
                }
                .disabled(order != .blocks)
            } header: {
                Heading(title: "Blocks", hint: "Used by “By blocks”. Drag a row to reorder.")
            } footer: {
                SectionButtons(note: "Every block is always there, so no session drops out of the widget.") {
                    Button("Restore Defaults") {
                        model.update {
                            model.settings.setSessionOrder(.arrival)
                            model.settings.setSessionBlockOrder(SessionBlock.defaultOrder)
                        }
                        blocks = SessionBlock.defaultOrder
                    }
                }
            }
        }
        .onAppear { blocks = model.settings.sessionBlockOrder }
    }

    private var sessionOrder: Binding<SessionOrder> {
        Binding(
            get: { model.settings.sessionOrder },
            set: { order in model.update { model.settings.setSessionOrder(order) } }
        )
    }
}

/// The made-up list, playing while the pane is in sight.
struct OrderPreview: NSViewRepresentable {
    static let height: CGFloat = 170
    let model: SettingsModel
    let revision: Int

    static func caption(for order: SessionOrder) -> String {
        let held = "Rows hold their places while the pointer is over the widget."
        switch order {
        case .arrival: return "A made-up list. A session keeps its place until it closes. \(held)"
        case .recentActivity, .attention: return "A made-up list, one change every two seconds. \(held)"
        case .blocks: return "A made-up list, grouped by the blocks below. \(held)"
        }
    }

    func makeCoordinator() -> SessionOrderTab {
        SessionOrderTab(
            settings: model.settings,
            look: { [themes = model.themes] in themes.look },
            background: { [themes = model.themes, store = model.backgroundStore] in
                themes.widgetBackground(on: store.material)
            },
            opacity: { [store = model.backgroundStore] in store.opacity },
            rowLayouts: model.rowLayouts
        )
    }

    func makeNSView(context: Context) -> NSView {
        let holder = NSView()
        let preview = context.coordinator.preview
        preview.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: holder.topAnchor, constant: 6),
            preview.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
        ])
        return holder
    }

    func updateNSView(_ holder: NSView, context: Context) {
        context.coordinator.showCurrentValues()
        context.coordinator.setShown(model.isShown)
    }

    static func dismantleNSView(_ holder: NSView, coordinator: SessionOrderTab) {
        coordinator.setShown(false)
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let themes = model.themes
        Form {
            Section {
                Picker("Theme", selection: theme) {
                    ForEach(themes.themes, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                Picker("Mode", selection: mode) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            } footer: {
                SectionButtons(note: themeNote) {
                    Button("Show Theme Folder") { model.showThemeFolder() }
                    Button("Duplicate Theme…") { model.update { themes.duplicate() } }
                }
            }
            Section {
                Picker("Material", selection: material) {
                    ForEach(WidgetMaterial.allCases, id: \.self) { material in
                        Text(
                            material.needsLiquidGlass && !WidgetMaterial.systemHasLiquidGlass
                                ? "\(material.name) (macOS 26)" : material.name
                        )
                        .tag(material)
                    }
                }
                Slider(value: opacity, in: Double(WidgetBackgroundStore.minimumOpacity)...1) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.dotted")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                }
                .help("\(Int((model.backgroundStore.opacity * 100).rounded()))%")
                .disabled(model.backgroundStore.material.drawn == .solid)
                Picker("Size", selection: scale) {
                    ForEach(WidgetSettingsStore.offeredScales, id: \.self) { scale in
                        Text("\(Int((scale * 100).rounded()))%").tag(scale)
                    }
                }
            } header: {
                Text("Widget")
            } footer: {
                Footnote(materialNote)
            }
        }
    }

    private var themeNote: String {
        let problems = model.themes.problems
        guard problems.isEmpty else {
            return "Some theme files could not be read: " + problems.joined(separator: "; ")
        }
        return "A theme holds every colour and animation, for light and dark. Duplicate one to edit it as a file."
    }

    private var theme: Binding<String> {
        Binding(
            get: { model.themes.theme.name },
            set: { name in
                guard let theme = model.themes.themes.first(where: { $0.name == name }) else { return }
                model.update { model.themes.select(theme) }
            }
        )
    }

    private var mode: Binding<ThemeMode> {
        Binding(
            get: { model.themes.mode },
            set: { mode in model.update { model.themes.select(mode) } }
        )
    }

    private var material: Binding<WidgetMaterial> {
        Binding(
            get: { model.backgroundStore.material },
            set: { material in model.update { model.backgroundStore.selectMaterial(material) } }
        )
    }

    private var materialNote: String {
        switch model.backgroundStore.material.drawn {
        case .glass: "Glass is recommended: the desktop shows through, and the colour keeps text readable."
        case .clearGlass: "Clear glass shows more of the desktop. Best on a quiet wallpaper."
        case .frosted: "Frosted blurs what is behind the widget."
        case .solid: "Solid hides the desktop entirely, so opacity does not apply. Best on a busy wallpaper."
        }
    }

    private var opacity: Binding<Double> {
        Binding(
            get: { Double(model.backgroundStore.opacity) },
            set: { value in model.update { model.backgroundStore.selectOpacity(CGFloat(value)) } }
        )
    }

    private var scale: Binding<CGFloat> {
        Binding(
            get: {
                WidgetSettingsStore.offeredScales.min {
                    abs($0 - model.settings.scale) < abs($1 - model.settings.scale)
                } ?? 1
            },
            set: { value in model.update { model.settings.setScale(value) } }
        )
    }
}

/// The recorder: a button that takes the next key press, which only an AppKit control can do.
struct ShortcutField: NSViewRepresentable {
    let model: SettingsModel
    let revision: Int

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let recorder = ShortcutRecorderButton(title: shortcutEmptyButton, target: nil, action: nil)
        recorder.bezelStyle = .rounded
        recorder.toolTip = shortcutAcceptedKeys
        recorder.target = context.coordinator
        recorder.action = #selector(Coordinator.start)
        recorder.onRecording = { [weak model] recording in
            model?.shortcutRecorded(recording)
        }
        model.shortcutRecorder = recorder
        return recorder
    }

    func updateNSView(_ recorder: ShortcutRecorderButton, context: Context) {
        recorder.title =
            recorder.isRecording
            ? shortcutRecordingButton
            : (model.settings.toggleShortcut?.displayed ?? shortcutEmptyButton)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: SettingsModel

        init(model: SettingsModel) {
            self.model = model
        }

        @objc func start() {
            model.startRecordingShortcut()
        }
    }
}

// MARK: - Menu bar

struct MenuBarPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let settings = model.settings
        let iconShows = settings.menuBarIconAttentions
        Form {
            Section("Icon") {
                Picker("Style", selection: iconStyle) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Text(style.name).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                ForEach(SessionAttention.counted, id: \.self) { attention in
                    Toggle(attention.name, isOn: iconShowing(attention))
                        .disabled(iconShows.contains(attention) && iconShows.count == 1)
                }
            }
            Section {
                Toggle("List sessions in the menu", isOn: listsSessions)
                ForEach(SessionAttention.counted, id: \.self) { attention in
                    Toggle(attention.name, isOn: menuListing(attention))
                        .disabled(!settings.listsSessionsInMenu)
                }
            } header: {
                Text("Menu")
            } footer: {
                Footnote("Listed sessions appear under the summary line; clicking one brings its window forward.")
            }
        }
    }

    private var iconStyle: Binding<MenuBarIconStyle> {
        Binding(
            get: { model.settings.menuBarIconStyle },
            set: { style in model.update { model.settings.setMenuBarIconStyle(style) } }
        )
    }

    private func iconShowing(_ attention: SessionAttention) -> Binding<Bool> {
        Binding(
            get: { model.settings.menuBarIconAttentions.contains(attention) },
            set: { on in model.update { model.settings.setMenuBarIconShows(attention, on) } }
        )
    }

    private var listsSessions: Binding<Bool> {
        Binding(
            get: { model.settings.listsSessionsInMenu },
            set: { on in model.update { model.settings.setListsSessionsInMenu(on) } }
        )
    }

    private func menuListing(_ attention: SessionAttention) -> Binding<Bool> {
        Binding(
            get: { model.settings.menuSessionAttentions.contains(attention) },
            set: { on in model.update { model.settings.setMenuLists(attention, on) } }
        )
    }
}

// MARK: - Behavior

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Show widget", isOn: showsWidget)
                    .help("Showing the widget also flashes it, so it is easy to find")
                Toggle("Lock position", isOn: locksPosition)
                    .help("Stops an accidental drag from moving the widget")
                Toggle("Lock size", isOn: locksSize)
                    .help("Stops an accidental drag on an edge from resizing the widget")
            } header: {
                Text("Widget")
            } footer: {
                SectionButtons {
                    Button("Reset Position") { model.resetWidgetPosition() }
                    Button("Reset Size") { model.resetWidgetSize() }
                }
            }
            Section {
                LabeledContent("Show and hide widget") {
                    HStack {
                        ShortcutField(model: model, revision: model.revision)
                            .frame(width: 168, height: 24)
                        Button(shortcutClearTitle) { model.clearShortcut() }
                            .disabled(model.settings.toggleShortcut == nil)
                    }
                }
            } header: {
                Text(shortcutSectionTitle)
            } footer: {
                Footnote(model.shortcutStatus)
            }
            Section("Closed sessions") {
                Picker("Closed sessions", selection: retention) {
                    ForEach(WidgetSettingsStore.offeredClosedSessionRetentions, id: \.seconds) { retention in
                        Text(StatusMenu.title(for: retention)).tag(retention.seconds)
                    }
                }
            }
            Section {
                Picker("Read transcripts", selection: transcripts) {
                    ForEach(WidgetSettingsStore.offeredTranscriptPollIntervals, id: \.self) { interval in
                        Text(transcriptIntervalMenuTitle(interval: interval)).tag(interval)
                    }
                }
            } header: {
                Text("Transcripts")
            } footer: {
                Footnote(model.transcriptSummary)
            }
            Section("Updates") {
                LabeledContent("Version") {
                    HStack {
                        Text(model.version ?? "Development build")
                        Button("Check Now") { model.checkForUpdates() }
                    }
                }
                Toggle("Check for updates on launch", isOn: checksOnLaunch)
            }
        }
    }

    private var checksOnLaunch: Binding<Bool> {
        Binding(
            get: { model.checksForUpdatesOnLaunch },
            set: { model.checksForUpdatesOnLaunch = $0 }
        )
    }

    private var showsWidget: Binding<Bool> {
        Binding(
            get: { model.isWidgetVisible },
            set: { model.isWidgetVisible = $0 }
        )
    }

    private var locksPosition: Binding<Bool> {
        Binding(
            get: { model.settings.locksPosition },
            set: { on in model.update { model.settings.setLocksPosition(on) } }
        )
    }

    private var locksSize: Binding<Bool> {
        Binding(
            get: { model.settings.locksSize },
            set: { on in model.update { model.settings.setLocksSize(on) } }
        )
    }

    private var retention: Binding<TimeInterval> {
        Binding(
            get: { model.settings.closedSessionRetention.seconds },
            set: { seconds in
                model.update { model.settings.setClosedSessionRetention(ClosedSessionRetention(seconds: seconds)) }
            }
        )
    }

    private var transcripts: Binding<TimeInterval?> {
        Binding(
            get: { model.settings.transcriptPollInterval },
            set: { interval in model.update { model.settings.setTranscriptPollInterval(interval) } }
        )
    }
}

// MARK: - Tooling

/// The hooks, the status line and the IDE plugins live in their own window, which is reworked
/// separately; this pane is the way to it.
struct ToolingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Hooks, status line and IDE plugins") {
                    Button("Open Tooling…") { model.showTooling() }
                }
            } footer: {
                Footnote("Install or repair what connects Claude Code, Codex and your IDE to Agent Watch.")
            }
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        Form {
            Section {
                LabeledContent("Event log") {
                    Button(model.isEventLogVisible ? "Hide Event Log" : "Show Event Log") { model.toggleEventLog() }
                }
            } footer: {
                Footnote("Every hook event Agent Watch receives, as it arrives.")
            }
            #if AGENT_WATCH_DEBUG_CAPTURE
                Section {
                    Toggle("Record raw hook payloads for 30 minutes", isOn: recording)
                    LabeledContent("Recorded") {
                        HStack {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(model.recordedPayloadBytes), countStyle: .file))
                            Button("Delete") { model.deleteRawHookRecordings() }
                                .disabled(model.recordedPayloadBytes == 0)
                        }
                    }
                } header: {
                    Text("Raw hook payloads")
                } footer: {
                    Footnote(recordingNote)
                }
            #endif
        }
    }

    #if AGENT_WATCH_DEBUG_CAPTURE
        private var recording: Binding<Bool> {
            Binding(
                get: { (model.rawCaptureExpiry ?? .distantPast) > .now },
                set: { _ in model.toggleRawHookCapture() }
            )
        }

        private var recordingNote: String {
            guard let expiry = model.rawCaptureExpiry, expiry > .now else {
                return "Debug builds only. Payloads are saved locally, never sent anywhere."
            }
            let minutes = max(1, Int(ceil(expiry.timeIntervalSince(.now) / 60)))
            return "Recording stops in \(minutes) min. Payloads are saved locally, never sent anywhere."
        }
    #endif
}
