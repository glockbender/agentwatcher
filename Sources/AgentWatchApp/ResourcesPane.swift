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
                Toggle("In a widget row's card", isOn: showsInCard)
                    .disabled(!isOn)
            } header: {
                Text("Show")
            } footer: {
                // One line in both states, so the page does not move when watching is switched.
                Footnote(
                    isOn
                        ? "A row shows its own figures as a part: add Memory & CPU in Rows."
                        : "Turn on watching above to show the figures.")
            }
            Section {
                ForEach(Self.lines(report: model.resourceReport, isOn: isOn), id: \.title) { line in
                    LabeledContent(line.title, value: line.value)
                }
            } header: {
                Text("This Mac now")
            } footer: {
                Footnote(
                    "Memory is what Activity Monitor shows for each process, and the parts can add up to more than "
                        + "is in use when memory is compressed or swapped. CPU counts one busy core as 100%, as "
                        + "Activity Monitor does.")
            }
        }
    }

    struct Line: Equatable {
        let title: String
        let value: String
    }

    static let titles = [
        "Memory in use", "CPU", "Agents", "Claude and ChatGPT apps", "Agent Watch", "Left by closed sessions",
        "Everything else",
    ]

    /// The same lines whatever the state, so nothing moves when watching is switched or a reading
    /// arrives.
    static func lines(report: ResourceReport?, isOn: Bool) -> [Line] {
        guard isOn else {
            return titles.map { Line(title: $0, value: "Off") }
        }
        guard let report else {
            return titles.map { Line(title: $0, value: "Reading…") }
        }
        let own = report.agentWatch.map { usage in
            ResourceFormat.short(ResourceFigure(footprint: usage.footprint, cpuLoad: report.agentWatchLoad))
        }
        guard let machine = report.machineFigure else {
            let values = [
                "Not read", "Not read", ResourceFormat.short(report.agents), "Not read", own ?? "Not read",
                ResourceFormat.memory(report.totals.unattributed.footprint), "Not read",
            ]
            return zip(titles, values).map { Line(title: $0, value: $1) }
        }
        let values = [
            ResourceFormat.memoryInUse(machine),
            machine.load.map { ResourceFormat.share($0, of: machine.cores) } ?? "Reading…",
            ResourceFormat.short(machine.agents),
            report.applications.isEmpty ? "Not running" : ResourceFormat.short(machine.applications),
            own ?? "Not read",
            ResourceFormat.memory(machine.leftBehind.footprint),
            ResourceFormat.short(machine.everythingElse),
        ]
        return zip(titles, values).map { Line(title: $0, value: $1) }
    }

    private var watches: Binding<Bool> {
        Binding(get: { model.watchesResources }, set: { model.watchesResources = $0 })
    }

    private var showsInMenu: Binding<Bool> {
        Binding(get: { model.showsResourcesInMenu }, set: { model.showsResourcesInMenu = $0 })
    }

    private var showsInCard: Binding<Bool> {
        Binding(get: { model.showsResourcesInCard }, set: { model.showsResourcesInCard = $0 })
    }
}
