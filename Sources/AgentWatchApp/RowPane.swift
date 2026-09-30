import AgentWatchCore
import AppKit
import SwiftUI
// MARK: - Row

/// The parts, in one list that never reorders itself: switching a part off leaves it where it
/// is, and only a drag moves anything.
struct RowPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let layout = model.layout
        Form {
            Section {
                SampleRowsView(model: model, revision: model.revision)
                    .frame(height: SampleRowsView.height)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                ReorderTable(items: $model.listedParts) {
                    model.reorderParts($0)
                } row: { part in
                    PartRow(model: model, part: part, layout: layout)
                }
            } header: {
                Heading(title: "Parts", hint: "Drag a row to reorder. Hover a part to read more about when it appears.")
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
                    Button("Restore Defaults") { model.restoreRowDefaults() }
                }
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

    /// What is said beside a part's switch, where it can be read without hovering: when the
    /// part appears, or why the last one cannot be switched off.
    static func note(for part: RowPart, in layout: RowLayout) -> String {
        isLast(part, in: layout) ? "stays: a row has to draw something" : part.appearsWhenBriefly
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
                Text(RowPartList.note(for: part, in: layout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            set: { on in model.switchPart(part, on: on) }
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
            set: { on in model.countActivity(kind, on) }
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
        NSView()
    }

    func updateNSView(_ holder: NSView, context: Context) {
        holder.subviews.forEach { $0.removeFromSuperview() }
        let background = model.themes.textBackground
        let panel = makeBackgroundView(for: background, opacity: model.themes.look.widgetOpacity)
        panel.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(panel)
        panel.pinToEdges(of: holder)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.content.addSubview(stack)
        stack.pinToEdges(of: holder)
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
