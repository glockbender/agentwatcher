import AppKit

@testable import AgentWatchApp

/// Stands in for the system's table of shortcuts, which a test may not write to: registering a
/// real combination would take it from every other application on the machine for as long as the
/// test ran.
@MainActor
final class FakeShortcutRegistrar: GlobalShortcutRegistering {
    enum Call: Equatable {
        case register(String)
        case unregister
    }

    var onPress: (() -> Void)?
    var answer: ShortcutRegistrationOutcome = .registered
    private(set) var calls: [Call] = []

    func register(_ shortcut: WidgetShortcut) -> ShortcutRegistrationOutcome {
        calls.append(.register(shortcut.stored))
        return answer
    }

    func unregister() {
        calls.append(.unregister)
    }

    func forgetCalls() {
        calls = []
    }

    func press() {
        onPress?()
    }
}

extension FakeShortcutRegistrar {
    /// A shortcut controller whose registrations go nowhere, for the tests that need a settings
    /// window and do not care about the shortcut in it.
    @MainActor
    static func controller(
        for settings: WidgetSettingsStore,
        answer: ShortcutRegistrationOutcome = .registered
    ) -> WidgetShortcutController {
        let registrar = FakeShortcutRegistrar()
        registrar.answer = answer
        let controller = WidgetShortcutController(settings: settings, registrar: registrar, onToggle: {})
        controller.apply()
        return controller
    }
}
