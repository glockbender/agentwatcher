import AgentWatchCore
import AppKit
import SwiftUI

/// The hooks, the status line and the IDE plugins live in their own window; this pane is the
/// way to it.
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
