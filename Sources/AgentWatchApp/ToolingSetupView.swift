import AgentWatchCore
import AppKit

func agentInstallationText(_ path: String?) -> String {
    path == nil ? "○ Not found in common locations · you can still connect it" : "✓ Installed on this Mac"
}

/// How the guide says the widget is shown and hidden. The combination only while it works: a
/// guide that printed a dead one would promise what the menu, for the same reason, will not.
func setupWidgetToggleText(shortcut: String?) -> String {
    guard let shortcut else {
        return "Show Widget in the menu bar shows or hides the widget. A shortcut can be set in Widget Settings."
    }
    return "\(shortcut) shows or hides the widget (you can change this in Widget Settings)."
}

enum SetupAction {
    case choose(AgentSource), back, next, overview, press(ToolingPress)
}

/// A short guided view of the same installation facts and actions as Tooling.
@MainActor
final class ToolingSetupView: NSStackView {
    private let act: (SetupAction) -> Void
    private let bodyWidth: CGFloat = 540
    private var actions: [ObjectIdentifier: SetupAction] = [:]

    init(journey: SetupJourney, facts: ToolingWindowFacts, act: @escaping (SetupAction) -> Void) {
        self.act = act
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 18
        widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true
        addArrangedSubview(label("CONNECT YOUR AGENTS", size: 11, color: .secondaryLabelColor))
        addArrangedSubview(label("One place to see who needs you", size: 23, weight: .semibold))
        addArrangedSubview(
            label("Choose an agent, connect it, then see its first signal. You can add the other agent later."))
        let steps = NSStackView(
            views: ["1  Choose", "2  Connect", "3  Try it"].enumerated().map { index, title in
                let active = index == min(journey.step.rawValue, 2)
                let text = NSTextField(labelWithString: title)
                text.font = .systemFont(ofSize: 13, weight: active ? .bold : .regular)
                text.textColor = active ? .controlAccentColor : .secondaryLabelColor
                return text
            })
        steps.spacing = 28
        addArrangedSubview(steps)

        switch journey.step {
        case .choose:
            for source in AgentSource.allCases {
                let card = column()
                let icon = NSImageView(image: AgentIcon.image(for: source, size: NSSize(width: 28, height: 28)))
                let title = NSTextField(labelWithString: AgentIcon.name(for: source))
                title.font = .systemFont(ofSize: 17, weight: .semibold)
                card.addArrangedSubview(NSStackView(views: [icon, title]))
                card.addArrangedSubview(label(agentInstallationText(facts.agentPaths[source]), width: bodyWidth - 32))
                if let path = facts.agentPaths[source] {
                    let detail = label(path, size: 11, color: .secondaryLabelColor, width: bodyWidth - 32)
                    detail.isSelectable = true
                    card.addArrangedSubview(detail)
                }
                card.addArrangedSubview(label(connectionBadge(facts.hookState(source)), width: bodyWidth - 32))
                card.addArrangedSubview(button("Set Up \(AgentIcon.name(for: source))", .choose(source)))
                addArrangedSubview(card)
            }
        case .connect:
            if let source = journey.source { connect(source, facts: facts) }
        case .verify, .ready:
            if let source = journey.source { verify(source, ready: journey.step == .ready, facts: facts) }
        }
        if let error = facts.lastError {
            addArrangedSubview(label(error, color: .systemRed))
        }
        let footer = NSStackView()
        footer.spacing = 12
        if journey.step != .choose { footer.addArrangedSubview(button("Back", .back)) }
        footer.addArrangedSubview(
            button(journey.step == .ready ? "Done · Open Tooling" : "Finish Later · Open Tooling", .overview))
        addArrangedSubview(footer)
        addArrangedSubview(
            label(
                "Set Up Again in Tooling reopens this guide. Your sessions and appearance stay as they are.", size: 11,
                color: .secondaryLabelColor))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func connect(_ source: AgentSource, facts: ToolingWindowFacts) {
        let state = facts.hookState(source)
        let card = column(highlighted: true)
        card.addArrangedSubview(
            label("Connect \(AgentIcon.name(for: source))", size: 18, weight: .semibold, width: bodyWidth - 32))
        card.addArrangedSubview(
            label(
                "Hooks send small local signals when your agent starts work, needs an answer or finishes. This is what makes the widget useful.",
                width: bodyWidth - 32))
        card.addArrangedSubview(label(connectionBadge(state), width: bodyWidth - 32))
        let path = label(
            "Writes \(facts.hooksPath(source))", size: 11, color: .secondaryLabelColor, width: bodyWidth - 32)
        path.isSelectable = true
        card.addArrangedSubview(path)
        if state.wantsInstalling, let title = toolingHookActionTitle(state: state) {
            card.addArrangedSubview(
                button("\(title) Connection", .press(.install(.init(source: source, kind: .hooks)))))
        }
        if state == .unreadable {
            card.addArrangedSubview(
                label(
                    toolingHookNextStep(state: state, source: source, path: facts.hooksPath(source)) ?? "",
                    width: bodyWidth - 32))
        }
        addArrangedSubview(card)
        if source == .claude {
            addArrangedSubview(label("Optional · context and usage", size: 15, weight: .semibold))
            addArrangedSubview(
                label(
                    "Connect Claude’s status line to see context size and account usage. Your existing command is preserved. This adds a process per refresh; the agent’s turn does not wait for it.",
                    size: 12))
            if case .connected = facts.statusLineState {
                addArrangedSubview(label("✓ Status line connected"))
            } else if facts.statusLineState == .unreadable {
                addArrangedSubview(label("Status line settings cannot be read. You can continue without it."))
            } else {
                addArrangedSubview(
                    button("Connect Status Line", .press(.install(.init(source: source, kind: .statusLine)))))
            }
        }
        let next = button("Continue →", .next)
        next.isEnabled = state == .installed || state == .unheard
        addArrangedSubview(next)
    }

    private func verify(_ source: AgentSource, ready: Bool, facts: ToolingWindowFacts) {
        let card = column(highlighted: true)
        card.addArrangedSubview(
            label(
                ready ? "✓ Your agent has reported to Agent Watch" : "Try your first session", size: 18,
                weight: .semibold, width: bodyWidth - 32))
        let instruction =
            source == .claude
            ? "Open Claude Code. In an existing session, run /reload-plugins, or start a new session. Then send a short request."
            : "Open Codex and accept its trust prompts for the new hooks. Then start a session and send a short request. Until you trust the hooks, no signals arrive."
        card.addArrangedSubview(label(instruction, width: bodyWidth - 32))
        card.addArrangedSubview(
            label(
                ready
                    ? "A signal has been received from this agent. Send a new request to confirm your current session in the widget."
                    : "Waiting for a signal… This page updates when an event arrives. You can leave it open while you try the agent.",
                width: bodyWidth - 32))
        if facts.hookState(source) != .installed && facts.hookState(source) != .unheard {
            card.addArrangedSubview(
                label("The connection needs attention. Go Back to repair it.", width: bodyWidth - 32))
        }
        addArrangedSubview(card)
        addArrangedSubview(label("Read the widget", size: 15, weight: .semibold))
        addArrangedSubview(
            label(
                "Working → Needs you → Done\nClick a session to return to it. Hover for details. "
                    + setupWidgetToggleText(shortcut: facts.widgetShortcut)
            ))
        addArrangedSubview(label("Using a JetBrains terminal?", size: 15, weight: .semibold))
        addArrangedSubview(
            label(
                "The optional IDE plugin lets a click select the exact terminal tab. Open Tooling below for installation and the Check button.",
                size: 12))
    }

    private func connectionBadge(_ state: ToolingInstallationState) -> String {
        switch state {
        case .installed: "✓ Connection installed"
        case .unheard: "◷ Connection installed · waiting for a signal"
        case .absent: "○ Not connected yet"
        case .incomplete, .stale: "! Connection needs repair"
        case .unreadable: "! Configuration cannot be read"
        }
    }

    private func label(
        _ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor, width: CGFloat? = nil
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.preferredMaxLayoutWidth = width ?? bodyWidth
        label.widthAnchor.constraint(equalToConstant: width ?? bodyWidth).isActive = true
        return label
    }

    private func column(highlighted: Bool = false) -> NSStackView {
        let card = SetupCard(highlighted: highlighted)
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 10
        card.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true
        return card
    }

    private func button(_ title: String, _ action: SetupAction) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
        button.bezelStyle = .rounded
        actions[ObjectIdentifier(button)] = action
        return button
    }

    @objc private func pressed(_ sender: NSButton) {
        if let action = actions[ObjectIdentifier(sender)] { act(action) }
    }
}

@MainActor
private final class SetupCard: NSStackView {
    private let highlighted: Bool

    init(highlighted: Bool) {
        self.highlighted = highlighted
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 12
            layer?.backgroundColor =
                NSColor.windowBackgroundColor.blended(
                    withFraction: highlighted ? 0.09 : 0.04, of: .controlAccentColor)?.cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(highlighted ? 0.8 : 0.2).cgColor
            layer?.borderWidth = highlighted ? 2 : 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
