import AgentWatchCore
import AppKit
import SwiftUI
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
