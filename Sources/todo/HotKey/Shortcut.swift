import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, and how to print it the way macOS does.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    // MARK: - Defaults

    /// ⌥Space to show and hide the panel.
    static let defaultOpen = Shortcut(keyCode: 49, modifiers: UInt32(optionKey))

    /// ⌃⌥⌘Q to quit. `todo` has no Dock icon and no menu bar item, so this is
    /// the only way to stop it while it is running.
    static let defaultQuit = Shortcut(keyCode: 12, modifiers: UInt32(controlKey | optionKey | cmdKey))

    // MARK: - Carbon modifier conversion

    private static let carbonMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: Shortcut.carbonModifiers(from: event.modifierFlags)
        )
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    // MARK: - Display

    var display: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts + Shortcut.symbol(for: keyCode)
    }

    /// macOS virtual key codes for the a–z row.
///
/// These are *not* a sequential offset — `a` is 0 but `q` is 12 and `p` is 35,
/// because the codes follow the physical ANSI/ISO key positions. An earlier
/// version assumed an offset and printed ⌃⌥⌘M for a shortcut that was really
/// ⌃⌥⌘Q: the hotkey still worked, but the UI told the user the wrong thing.
private static let letters: [UInt32: Character] = [
    0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
    34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
    12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
    16: "Y", 6: "Z",
]

/// Number row, same reasoning.
private static let numbers: [UInt32: Character] = [
    29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
    28: "8", 24: "9",
]

private static let named: [UInt32: String] = [
    36: "↩",   // return
    76: "⌤",        // keypad enter
    48: "⇥",         // tab
    49: "space",
    51: "⌫",        // backspace
    53: "esc",
    114: "help",
    115: "home",
    116: "⇞",
    117: "⌦",        // forward delete
    119: "end",
    121: "⇟",
    123: "←",
    124: "→",
    125: "↓",
    126: "↑",
]

static func symbol(for keyCode: UInt32) -> String {
    if let letter = letters[keyCode] { return String(letter) }
    if let number = numbers[keyCode] { return String(number) }
    if let name = named[keyCode] { return name }

    // Function keys F1–F20 are consecutive from 122 upward on macOS.
    if keyCode >= 122 && keyCode <= 141 {
        return "F\(keyCode - 121)"
    }

    return "key \(keyCode)"
}
}

/// Persists the chosen shortcuts.
enum ShortcutStore {
    private static let openKey = "todo.shortcut.open"
    private static let quitKey = "todo.shortcut.quit"

    static var open: Shortcut {
        get { load(openKey) ?? .defaultOpen }
        set { save(newValue, openKey) }
    }

    static var quit: Shortcut {
        get { load(quitKey) ?? .defaultQuit }
        set { save(newValue, quitKey) }
    }

    private static func load(_ key: String) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private static func save(_ shortcut: Shortcut, _ key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}