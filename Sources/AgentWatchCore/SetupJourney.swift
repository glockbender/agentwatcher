/// Navigation only. Installation and delivery remain facts supplied by their owners.
public struct SetupJourney: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        case choose, connect, verify, ready
    }

    public private(set) var step: Step = .choose
    public private(set) var source: AgentSource?

    public init() {}

    public mutating func choose(_ source: AgentSource) {
        self.source = source
        step = .connect
    }

    public mutating func continueToVerification(hooks: ToolingInstallationState) {
        guard source != nil, step == .connect, hooks == .installed || hooks == .unheard else { return }
        step = .verify
    }

    public mutating func observe(hooks: ToolingInstallationState, receivedEvent: Bool) {
        guard step == .verify || step == .ready else { return }
        step = hooks == .installed && receivedEvent ? .ready : .verify
    }

    public mutating func back() {
        switch step {
        case .choose: break
        case .connect: step = .choose
        case .verify, .ready: step = .connect
        }
    }
}
