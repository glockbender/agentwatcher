import AgentWatchCore
import AppKit
import SwiftUI
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
                        model.restoreOrderDefaults()
                        blocks = model.settings.sessionBlockOrder
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
            background: { [themes = model.themes] in themes.textBackground },
            opacity: { [themes = model.themes] in themes.look.widgetOpacity },
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
