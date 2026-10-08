import AgentWatchCore
import AppKit
import SwiftUI

/// Everything Agent Watch has written into other programs, and the presses that change it.
///
/// Mostly text, and that is the point rather than a shortcut. This app edits files that belong
/// to other programs, and a person is entitled to see which file, what is in it, and what is
/// left for them to do — before pressing anything, and without opening a terminal.
struct ToolingPane: View {
    @ObservedObject var tooling: ToolingModel

    var body: some View {
        // One container, so the page is opened once per visit: a modifier on a `Group` would
        // reach each branch, and moving between the guide and the overview would count as a
        // new visit and drop the error the person came back to read.
        VStack(spacing: 0) {
            if let journey = tooling.journey {
                SetupGuide(tooling: tooling, journey: journey)
            } else {
                ToolingOverview(tooling: tooling)
            }
        }
        .onAppear { tooling.pageOpened() }
    }
}

/// A section per agent, a row per integration, then the IDEs.
private struct ToolingOverview: View {
    @ObservedObject var tooling: ToolingModel

    var body: some View {
        let reading = tooling.reading
        let sections = tooling.sections
        Form {
            Section {
                LabeledContent("Step-by-step setup") {
                    Button("Set Up Again…") { tooling.startSetup() }
                }
            } footer: {
                Footnote("Nothing is removed or reinstalled until you press a button.")
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                Section {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        ToolingRow(row: row, press: tooling.press)
                    }
                } header: {
                    if AgentSource.allCases.indices.contains(index) {
                        Heading(
                            title: section.title,
                            hint: agentInstallationText(reading.agentPaths[AgentSource.allCases[index]]))
                    } else {
                        Text(section.title)
                    }
                }
            }
            if let sender = ToolingReport.senderNote(
                senderPath: reading.senderPath, isTiedToThisBuild: reading.senderIsTiedToThisBuild)
            {
                Section {
                    ToolingRow(row: sender, press: tooling.press)
                }
            }
            if let error = reading.lastError {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }
}

/// One integration: what it is, where it stands, the file, what is left to do, and its buttons.
private struct ToolingRow: View {
    let row: ToolingReportRow
    let press: (ToolingPress) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                title
                Text(row.state).foregroundStyle(.secondary)
                ForEach(row.details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                // The one thing on the row addressed to the person rather than describing the
                // disk, so it is the one thing that is not grey.
                if let nextStep = row.nextStep {
                    Text(nextStep)
                }
            }
            // Selectable, so a path can be copied out of here instead of retyped. It is the only
            // reason a person would reach for a terminal after reading this page.
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Beside the text rather than under it: a row is one thing, and a press below its
            // own explanation reads as belonging to the row after it.
            if !row.actions.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(row.actions, id: \.press) { action in
                        Button(action.title) { press(action.press) }
                            .disabled(!action.isEnabled)
                            .help(action.hint ?? "")
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    /// A dot in front of the name when the row is about something that can be running. Never the
    /// only carrier: the row says "Not running" in words wherever that changes what can be done.
    @ViewBuilder private var title: some View {
        if let status = row.status {
            (Text("● ").foregroundColor(status == .running ? .green : Color(nsColor: .tertiaryLabelColor))
                + Text(row.title))
                .fontWeight(.semibold)
                .help(toolingStatusHint(status))
        } else {
            Text(row.title).fontWeight(.semibold)
        }
    }
}

/// The guided way through the same facts and presses: choose an agent, connect it, see its
/// first signal. Its buttons stay at the bottom of the page whatever the step's length.
private struct SetupGuide: View {
    @ObservedObject var tooling: ToolingModel
    let journey: SetupJourney

    var body: some View {
        let reading = tooling.reading
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One place to see who needs you").font(.title2).fontWeight(.semibold)
                        Text(
                            "Choose an agent, connect it, then see its first signal. You can add the other agent later."
                        )
                        .foregroundStyle(.secondary)
                        SetupSteps(step: journey.step)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Connect your agents")
                }
                switch journey.step {
                case .choose:
                    ForEach(AgentSource.allCases, id: \.self) { source in
                        choice(source, reading)
                    }
                case .connect:
                    if let source = journey.source {
                        connection(source, reading)
                    }
                case .verify, .ready:
                    if let source = journey.source {
                        verification(source, ready: journey.step == .ready, reading)
                    }
                }
                if let error = reading.lastError {
                    Section {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            Divider()
            HStack {
                if journey.step != .choose {
                    Button("Back") { tooling.back() }
                }
                Spacer()
                Button(journey.step == .ready ? "Done" : "Finish Later") { tooling.finishSetup() }
                if journey.step == .connect {
                    Button("Continue →") { tooling.continueToVerification() }
                        .disabled(!tooling.canContinue)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func choice(_ source: AgentSource, _ reading: ToolingFacts) -> some View {
        let name = AgentIcon.name(for: source)
        return Section {
            HStack(spacing: 10) {
                Image(nsImage: AgentIcon.image(for: source, size: NSSize(width: 28, height: 28)))
                Text(name).font(.title3).fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(agentInstallationText(reading.agentPaths[source]))
                if let path = reading.agentPaths[source] {
                    Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            LabeledContent(setupConnectionText(reading.hookState(source))) {
                Button("Set Up \(name)") { tooling.choose(source) }
            }
        }
    }

    @ViewBuilder
    private func connection(_ source: AgentSource, _ reading: ToolingFacts) -> some View {
        let state = reading.hookState(source)
        Section {
            Text(
                "Hooks send small local signals when your agent starts work, needs an answer or finishes. This is what makes the widget useful."
            )
            LabeledContent {
                if state.wantsInstalling, let title = toolingHookActionTitle(state: state) {
                    Button("\(title) Connection") { tooling.connect() }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(setupConnectionText(state))
                    Text("Writes \(reading.hooksPath(source))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if state == .unreadable,
                let nextStep = toolingHookNextStep(
                    state: state, source: source, path: reading.hooksPath(source))
            {
                Text(nextStep)
            }
        } header: {
            Text("Connect \(AgentIcon.name(for: source))")
        }
        if source == .claude {
            Section {
                LabeledContent("Status line") {
                    switch reading.statusLineState {
                    case .connected: Text("✓ Connected")
                    case .unreadable: Text("Settings cannot be read")
                    case .notSet, .theirs: Button("Connect Status Line") { tooling.connectStatusLine() }
                    }
                }
            } header: {
                Text("Optional · context and usage")
            } footer: {
                Footnote(statusLineNote(reading.statusLineState))
            }
        }
    }

    private func statusLineNote(_ state: StatusLineState) -> String {
        guard state != .unreadable else {
            return
                "Claude’s settings file cannot be read, so the status line is left alone. You can continue without it."
        }
        return
            "Shows context size and account usage. Your existing command is preserved. This adds a process per refresh; the agent’s turn does not wait for it."
    }

    @ViewBuilder
    private func verification(_ source: AgentSource, ready: Bool, _ reading: ToolingFacts) -> some View {
        let state = reading.hookState(source)
        Section {
            Text(
                source == .claude
                    ? "Open Claude Code. In an existing session, run /reload-plugins, or start a new session. Then send a short request."
                    : "Open Codex and accept its trust prompts for the new hooks. Then start a session and send a short request. Until you trust the hooks, no signals arrive."
            )
            Text(
                ready
                    ? "A signal has been received from this agent. Send a new request to confirm your current session in the widget."
                    : "Waiting for a signal… This page updates when an event arrives. You can leave it open while you try the agent."
            )
            .foregroundStyle(.secondary)
            if state != .installed && state != .unheard {
                Text("The connection needs attention. Go Back to repair it.")
            }
        } header: {
            Text(ready ? "✓ Your agent has reported to Agent Watch" : "Try your first session")
        }
        Section("Read the widget") {
            Text(
                "Working → Needs you → Done\nClick a session to return to it. Hover for details. "
                    + setupWidgetToggleText(shortcut: reading.widgetShortcut))
        }
        Section("Using a JetBrains terminal?") {
            Text(
                "The optional IDE plugin lets a click select the exact terminal tab. Finish this guide to install it and check it on this page."
            )
        }
    }
}

/// Where the guide is: three steps, the current one in the accent colour.
private struct SetupSteps: View {
    let step: SetupJourney.Step

    var body: some View {
        HStack(spacing: 28) {
            ForEach(Array(["1  Choose", "2  Connect", "3  Try it"].enumerated()), id: \.offset) { index, title in
                let active = index == min(step.rawValue, 2)
                Text(title)
                    .fontWeight(active ? .bold : .regular)
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
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
