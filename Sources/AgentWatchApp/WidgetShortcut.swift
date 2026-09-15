import AppKit

/// A key combination the system hands to this application even while another one has the focus.
///
/// Held as a key **code** rather than a letter, and this is the whole reason the type exists
/// instead of a string. A code names a place on the keyboard — 13 is where `W` sits on a US
/// layout — and that is what the system registers. Storing the letter would leave the shortcut
/// dead as soon as somebody switched to a layout that prints something else on that key.
/// [ADR-0008](../../docs/adr/0008-the-global-shortcut-goes-through-carbon.md).
struct WidgetShortcut: Equatable {
    /// The keys held down alongside the one that is pressed.
    ///
    /// Its own type rather than `NSEvent.ModifierFlags` because a stored setting outlives the
    /// framework's representation of it, and because the flags carry more than this app may act
    /// on — Caps Lock and the function key arrive in the same set and must not become part of a
    /// shortcut.
    struct Modifiers: OptionSet {
        let rawValue: Int

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    let keyCode: UInt16
    let modifiers: Modifiers
    /// Settled at construction, where the key was checked anyway. Looking it up again in every
    /// reader would leave each of them with a "no such key" case that the initialiser has
    /// already made impossible — and that no test could reach to prove right.
    private let key: Key

    /// Nothing is accepted that this app cannot name and cannot hand to a menu.
    ///
    /// Both halves matter. Without a modifier the combination would be a bare key, and the
    /// handler fires wherever it is pressed — the widget would appear and vanish on every `w`
    /// typed anywhere on the machine. Without a name there is nothing to print in the settings
    /// row or beside the menu line, and a shortcut a person cannot read back is one they cannot
    /// change on purpose.
    ///
    /// Function keys are the exception, and the only one: nobody types `F13` into a document, so
    /// taking it from the whole machine costs nothing, and `F13`–`F19` sit on a full keyboard
    /// with nothing else asking for them. The system was never the obstacle here —
    /// `RegisterEventHotKey` takes a bare `F5` and answers `noErr`, measured.
    ///
    /// The exception stops there. An arrow reaches this app through the same kind of code point
    /// but is pressed constantly, so it keeps the rule.
    ///
    /// `fn` is not part of any of this and cannot be: Carbon's modifier mask has bits for
    /// `⌘⇧⌥⌃` and the right-hand halves of them, and none for `fn`. What `fn` decides is which
    /// event the hardware produces at all — `F5` or screen brightness — before a shortcut is
    /// ever matched. Somebody who records `F5` pressed whatever produces `F5` on their machine,
    /// and will press it the same way again.
    init?(keyCode: UInt16, modifiers: Modifiers) {
        guard let key = Self.keys[keyCode], !modifiers.isEmpty || key.standsAlone else {
            return nil
        }
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// What a person just pressed, taken as a shortcut — or nothing, if it is not one this app
    /// may use.
    ///
    /// The whole event is asked for rather than its parts, so that the one place that decides
    /// which modifier flags count is here, beside the set they are narrowed to.
    init?(press: NSEvent) {
        let held = Self.modifierNames.reduce(into: Modifiers()) { modifiers, entry in
            if press.modifierFlags.contains(entry.flag) {
                modifiers.insert(entry.modifier)
            }
        }
        self.init(keyCode: press.keyCode, modifiers: held)
    }

    /// The combination as macOS prints it, `⌥⌘W`.
    var displayed: String {
        Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.symbol).joined()
            + key.label
    }

    /// What `NSMenuItem.keyEquivalent` takes: the character alone, in lower case.
    ///
    /// An upper-case character is not the same request — AppKit reads it as the shifted key and
    /// prints a `⇧` nobody asked for.
    var menuKeyEquivalent: String {
        key.menuCharacter
    }

    /// What `NSMenuItem.keyEquivalentModifierMask` takes, the other half of the same request.
    var menuModifierMask: NSEvent.ModifierFlags {
        Self.modifierNames.reduce(into: NSEvent.ModifierFlags()) { mask, entry in
            if modifiers.contains(entry.modifier) {
                mask.insert(entry.flag)
            }
        }
    }

    /// What goes into the preferences file, and what comes back out of it.
    ///
    /// Readable on purpose: the file is one a person can open, and `opt+cmd+13` at least says
    /// which modifiers were meant even to somebody who has to look up the 13.
    var stored: String {
        (Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.name) + ["\(keyCode)"])
            .joined(separator: "+")
    }

    init?(stored: String) {
        var parts = stored.split(separator: "+").map(String.init)
        guard let code = parts.popLast().flatMap({ UInt16($0) }) else {
            return nil
        }
        var modifiers: Modifiers = []
        for part in parts {
            guard let known = Self.modifierNames.first(where: { $0.name == part }) else {
                return nil
            }
            modifiers.insert(known.modifier)
        }
        self.init(keyCode: code, modifiers: modifiers)
    }

    /// Listed in the order macOS itself prints them, `⌃⌥⇧⌘`, so that the stored form, the shown
    /// form and the menu all agree without any of them having to sort.
    private static let modifierNames:
        [(name: String, symbol: String, modifier: Modifiers, flag: NSEvent.ModifierFlags)] = [
            ("ctrl", "⌃", .control, .control),
            ("opt", "⌥", .option, .option),
            ("shift", "⇧", .shift, .shift),
            ("cmd", "⌘", .command, .command),
        ]

    /// A key this app is willing to put in a shortcut: what it is called on screen, and the
    /// character a menu wants for it.
    private struct Key: Equatable {
        let label: String
        let menuCharacter: String
        /// Whether this key may be a shortcut with nothing held down.
        ///
        /// Kept here, beside the key, rather than as a list of codes somewhere else: the rule is
        /// a property of the key, and a second list would be a second place to forget.
        let standsAlone: Bool

        /// For keys whose name on screen is already the character a menu wants, give or take
        /// the case — every letter and every digit.
        init(_ label: String) {
            self.init(label, menu: label.lowercased())
        }

        init(_ label: String, menu: String, standsAlone: Bool = false) {
            self.label = label
            menuCharacter = menu
            self.standsAlone = standsAlone
        }

        /// Keys with no printable character of their own reach a menu as a code point from the
        /// private range AppKit reserves for them.
        init(_ label: String, function: Int) {
            self.init(label, menu: String(format: "%C", function))
        }

        /// The one kind of key a shortcut may be made of on its own.
        static func functionKey(_ label: String, _ code: Int) -> Key {
            Key(label, menu: String(format: "%C", code), standsAlone: true)
        }
    }

    /// Every key a shortcut may use.
    ///
    /// The codes were read out of `HIToolbox`'s own `kVK_*` constants rather than typed from
    /// memory: a wrong number here would register the shortcut on one key and print another,
    /// and nothing else in the app would notice.
    ///
    /// Deliberately not the whole keyboard. Punctuation sits in different places on different
    /// layouts far more than letters do, so a shortcut set on one would read back as a lie.
    private static let keys: [UInt16: Key] = [
        0: Key("A"), 11: Key("B"), 8: Key("C"), 2: Key("D"), 14: Key("E"), 3: Key("F"),
        5: Key("G"), 4: Key("H"), 34: Key("I"), 38: Key("J"), 40: Key("K"), 37: Key("L"),
        46: Key("M"), 45: Key("N"), 31: Key("O"), 35: Key("P"), 12: Key("Q"), 15: Key("R"),
        1: Key("S"), 17: Key("T"), 32: Key("U"), 9: Key("V"), 13: Key("W"), 7: Key("X"),
        16: Key("Y"), 6: Key("Z"),
        29: Key("0"), 18: Key("1"), 19: Key("2"), 20: Key("3"), 21: Key("4"), 23: Key("5"),
        22: Key("6"), 26: Key("7"), 28: Key("8"), 25: Key("9"),
        122: .functionKey("F1", NSF1FunctionKey), 120: .functionKey("F2", NSF2FunctionKey),
        99: .functionKey("F3", NSF3FunctionKey), 118: .functionKey("F4", NSF4FunctionKey),
        96: .functionKey("F5", NSF5FunctionKey), 97: .functionKey("F6", NSF6FunctionKey),
        98: .functionKey("F7", NSF7FunctionKey), 100: .functionKey("F8", NSF8FunctionKey),
        101: .functionKey("F9", NSF9FunctionKey), 109: .functionKey("F10", NSF10FunctionKey),
        103: .functionKey("F11", NSF11FunctionKey), 111: .functionKey("F12", NSF12FunctionKey),
        105: .functionKey("F13", NSF13FunctionKey), 107: .functionKey("F14", NSF14FunctionKey),
        113: .functionKey("F15", NSF15FunctionKey), 106: .functionKey("F16", NSF16FunctionKey),
        64: .functionKey("F17", NSF17FunctionKey), 79: .functionKey("F18", NSF18FunctionKey),
        80: .functionKey("F19", NSF19FunctionKey),
        49: Key("Space", menu: " "), 36: Key("Return", menu: "\r"), 48: Key("Tab", menu: "\t"),
        123: Key("←", function: NSLeftArrowFunctionKey),
        124: Key("→", function: NSRightArrowFunctionKey),
        126: Key("↑", function: NSUpArrowFunctionKey),
        125: Key("↓", function: NSDownArrowFunctionKey),
    ]
}
