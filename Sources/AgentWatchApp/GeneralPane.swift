import AgentWatchCore
import AppKit
import SwiftUI

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
            Section {
                Toggle("Show headless runs", isOn: showsHeadlessRuns)
            } header: {
                Text("Headless runs")
            } footer: {
                Footnote(
                    "claude -p, Agent SDK runs and codex exec: a program starts them, and they have no window. "
                        + "Shown, a click on one offers to end it.")
            }
            Section("Closed sessions") {
                Picker("Closed sessions", selection: retention) {
                    ForEach(WidgetSettingsStore.offeredClosedSessionRetentions, id: \.seconds) { retention in
                        Text(retention.settingsTitle).tag(retention.seconds)
                    }
                }
            }
            Section {
                Picker("Read transcripts", selection: transcripts) {
                    ForEach(WidgetSettingsStore.offeredTranscriptPollIntervals, id: \.self) { interval in
                        Text(transcriptIntervalTitle(interval: interval)).tag(interval)
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

    private var showsHeadlessRuns: Binding<Bool> {
        Binding(
            get: { model.settings.showsHeadlessRuns },
            set: { on in model.update { model.settings.setShowsHeadlessRuns(on) } }
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

extension ClosedSessionRetention {
    var settingsTitle: String {
        switch self {
        case .manual:
            "Keep until dismissed"
        case let .after(seconds):
            seconds < 120
                ? "Remove after \(Int(seconds)) seconds"
                : "Remove after \(Int(seconds / 60)) minutes"
        }
    }
}
