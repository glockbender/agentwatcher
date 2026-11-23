import SwiftUI
import WidgetKit

private enum WidgetIdentity {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Agent Watch"
    }

    static var scheme: String {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "AgentWatchURLScheme") as? String else {
            preconditionFailure("The widget needs its containing app's URL scheme")
        }
        return scheme
    }
}

private enum Destination: String {
    case projects
    case waiting
    case settings

    var url: URL {
        guard let url = URL(string: "\(WidgetIdentity.scheme)://\(rawValue)") else {
            preconditionFailure("Invalid Agent Watch destination: \(rawValue)")
        }
        return url
    }
}

private struct Entry: TimelineEntry {
    let date: Date
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // These destinations do not change while the app is running or closed.
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

private struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(WidgetIdentity.name, systemImage: "waveform.path.ecg")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if family == .systemMedium {
                Link(destination: Destination.projects.url) {
                    Label("Projects & Recent", systemImage: "folder")
                        .font(.title3.weight(.semibold))
                }
                Divider().padding(.vertical, 8)
                HStack(spacing: 16) {
                    Link(destination: Destination.waiting.url) {
                        Label("Waiting for you", systemImage: "bubble.left")
                    }
                    Spacer(minLength: 0)
                    Link(destination: Destination.settings.url) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                .font(.subheadline)
            } else {
                Label("Projects & Recent", systemImage: "folder")
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(Destination.projects.url)
        .containerBackground(.background, for: .widget)
    }
}

@main
struct AgentWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "\(WidgetIdentity.scheme).launcher", provider: Provider()) { _ in
            LauncherView()
        }
        .configurationDisplayName(WidgetIdentity.name)
        .description("Open projects, find chats waiting for you, and reach Agent Watch settings.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
