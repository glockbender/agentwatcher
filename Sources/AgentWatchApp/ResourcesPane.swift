import AgentWatchCore
import SwiftUI

/// Whether the app watches what the agents cost, where it shows it, and what it reads now.
struct ResourcesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.revision
        let isOn = model.watchesResources
        Form {
            Section {
                Toggle("Watch what agents use", isOn: watches)
            } footer: {
                Footnote(
                    "Every 5 seconds while a session is open, Agent Watch reads the memory and processor time of "
                        + "each agent and of everything it started: MCP servers, commands, and what they left running.")
            }
            Section {
                Toggle("Beside the menu's summary", isOn: showsInMenu)
                    .disabled(!isOn)
            } header: {
                Text("Show")
            } footer: {
                // One line in both states, so the page does not move when watching is switched.
                Footnote(
                    isOn
                        ? "What the agents and everything they run use together."
                        : "Turn on watching above to show the figures.")
            }
            Section {
                ForEach(Self.lines(report: model.resourceReport, isOn: isOn), id: \.title) { line in
                    LabeledContent(line.title, value: line.value)
                }
            } header: {
                Text("Now")
            } footer: {
                Footnote(
                    "Memory is what Activity Monitor shows. CPU counts one busy core as 100%, as Activity Monitor "
                        + "does.")
            }
        }
    }

    struct Line: Equatable {
        let title: String
        let value: String
    }

    /// The same lines whatever the state, so nothing moves when watching is switched.
    static func lines(report: ResourceReport?, isOn: Bool) -> [Line] {
        guard isOn else {
            return [Line(title: "Agents", value: "Off"), Line(title: "Agent Watch", value: "Off")]
        }
        guard let report else {
            return [Line(title: "Agents", value: "Reading…"), Line(title: "Agent Watch", value: "Reading…")]
        }
        let own = report.agentWatch.map { usage in
            ResourceFormat.short(AgentsResourceFigure(footprint: usage.footprint, cpuLoad: report.agentWatchLoad))
        }
        return [
            Line(title: "Agents", value: ResourceFormat.short(report.agents)),
            Line(title: "Agent Watch", value: own ?? "Not read"),
        ]
    }

    private var watches: Binding<Bool> {
        Binding(get: { model.watchesResources }, set: { model.watchesResources = $0 })
    }

    private var showsInMenu: Binding<Bool> {
        Binding(get: { model.showsResourcesInMenu }, set: { model.showsResourcesInMenu = $0 })
    }
}
