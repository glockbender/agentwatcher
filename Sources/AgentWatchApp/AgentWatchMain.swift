import AgentWatchSender
import AppKit

@main
@MainActor
enum AgentWatchMain {
    static func main() {
        let application = NSApplication.shared
        let singleInstanceCoordinator = SingleInstanceCoordinator()
        guard singleInstanceCoordinator.mayLaunch() else {
            activateExistingInstance(using: singleInstanceCoordinator)
            return
        }
        let delegate = AppDelegate(singleInstanceCoordinator: singleInstanceCoordinator)

        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private static func activateExistingInstance(using coordinator: SingleInstanceCoordinator) {
        guard let socketURL = coordinator.socketURL() else {
            return
        }
        _ = LocalControlSender.requestRevealExistingInstance(to: socketURL.path)
    }
}
