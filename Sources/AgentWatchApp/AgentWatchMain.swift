import AgentWatchCore
import AgentWatchSender
import AppKit

@main
@MainActor
enum AgentWatchMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--git-hooks" {
            guard arguments.count == 5, let action = GitHookInstaller.Action(rawValue: arguments[2]),
                let source = AgentSource(rawValue: arguments[3]), arguments[4].hasPrefix("/")
            else {
                FileHandle.standardError.write(
                    Data(
                        "Usage: AgentWatch --git-hooks <status|install|remove> <claude|codex> <absolute-profile-folder>\n"
                            .utf8))
                exit(2)
            }
            do {
                let state = try GitHookInstaller(bundle: Bundle.main.bundleURL).apply(
                    action, source: source, profile: URL(fileURLWithPath: arguments[4], isDirectory: true))
                print(state.rawValue)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        }
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
