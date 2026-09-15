import AppKit
import Carbon.HIToolbox

/// What the machine said about a combination somebody chose.
enum ShortcutRegistrationOutcome: Equatable {
    case registered
    /// `eventHotKeyExistsErr`. Its own case because it means something specific, and not what its
    /// name in Carbon suggests.
    ///
    /// Measured on macOS 15.3.1: two separate applications register the same combination and both
    /// are told `noErr` — a press then reaches **both** of their handlers. The same call made
    /// twice inside one process is refused with this status, with a different `id` as well as
    /// with the same one. So the system counts a collision only within an application, and this
    /// status can only mean that Agent Watch is still holding the combination itself.
    ///
    /// The name states that measurement, so if a later macOS starts refusing a duplicate across
    /// applications the name becomes the lie `taken` was. `docs/measurements.md` carries the row
    /// to re-check, under macOS.
    case alreadyOurs
    case refused(code: Int32)
}

/// Puts a combination into the system's table of shortcuts, and takes it out again.
///
/// A protocol so the parts that decide *when* to register can be tested without registering:
/// a real registration lasts as long as the process does and reaches the whole machine, which is
/// not something a test run may leave behind.
@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    var onPress: (() -> Void)? { get set }

    func register(_ shortcut: WidgetShortcut) -> ShortcutRegistrationOutcome
    func unregister()
}

/// The one file that talks to Carbon, and the reason is in
/// [ADR-0008](../../docs/adr/0008-the-global-shortcut-goes-through-carbon.md): this application
/// is never the active one, and `RegisterEventHotKey` is the only way it can hear a key press
/// without asking for permission to read everything the person types.
@MainActor
final class GlobalShortcutRegistrar: GlobalShortcutRegistering {
    var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Four bytes the system uses to tell one application's shortcuts from another's: `AGWT`.
    private static let signature = OSType(0x4147_5754)

    /// The handler goes up once and stays up; only the shortcut itself comes and goes.
    ///
    /// Installing it per registration would leave a second handler behind on every change, and
    /// each of them would answer the same press.
    init() {
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<GlobalShortcutRegistrar>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                // Carbon delivers this on the main run loop, which the compiler cannot see.
                return MainActor.assumeIsolated { registrar.handle(event) }
            },
            1,
            &pressed,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    func register(_ shortcut: WidgetShortcut) -> ShortcutRegistrationOutcome {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(shortcut.modifiers),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return status == OSStatus(eventHotKeyExistsErr) ? .alreadyOurs : .refused(code: status)
        }
        hotKey = reference
        return .registered
    }

    func unregister() {
        guard let hotKey else {
            return
        }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressed
        )
        guard status == noErr, pressed.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }
        onPress?()
        return noErr
    }

    private static func carbonModifiers(_ modifiers: WidgetShortcut.Modifiers) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.control) {
            mask |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            mask |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            mask |= UInt32(shiftKey)
        }
        if modifiers.contains(.command) {
            mask |= UInt32(cmdKey)
        }
        return mask
    }
}
