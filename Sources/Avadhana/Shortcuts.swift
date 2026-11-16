import AppKit

/// A key plus modifiers, recorded from a real key press.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    /// NSEvent.ModifierFlags raw value, limited to ⌃ ⌥ ⇧ ⌘.
    var modifiers: UInt
    /// What to show for the key itself, e.g. "Esc", "⌫", "K".
    var key: String

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant).rawValue
        self.key = key
    }

    init(event: NSEvent) {
        let label = Self.specialKeys[event.keyCode]
            ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, key: label)
    }

    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode && self.flags == flags.intersection(Self.relevant)
    }

    /// ⌘ + a letter or number (and nothing else): most apps already use these.
    var isCommonAppShortcut: Bool {
        flags == .command && key.count == 1 && key.first.map { $0.isLetter || $0.isNumber } == true
    }

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    static let specialKeys: [UInt16: String] = [
        53: "Esc", 51: "⌫", 117: "⌦", 36: "↩", 76: "⌤", 48: "⇥", 49: "Space",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

struct ShortcutSetting: Codable, Equatable {
    var enabled: Bool
    var combo: KeyCombo
    /// Let the key press through to the app when you're typing in a text field.
    var ignoreWhileTyping: Bool
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case home, back, settings, gridLayout, rowsLayout

    var id: String { rawValue }

    /// Global shortcuts work while any app is in front; the rest only when Avadhāna is.
    var isGlobal: Bool { self == .home || self == .back }

    var title: String {
        switch self {
        case .home: return "Home"
        case .back: return "Back"
        case .settings: return "Settings"
        case .gridLayout: return "Grid layout"
        case .rowsLayout: return "Rows layout"
        }
    }

    var detail: String {
        switch self {
        case .home: return "Go to the home screen from any app or site."
        case .back: return "Previous page in a site; the home screen in an app."
        case .settings: return "Open this window."
        case .gridLayout: return "Home screen and main window."
        case .rowsLayout: return "Home screen and main window."
        }
    }

    var defaultSetting: ShortcutSetting {
        let combo: KeyCombo
        switch self {
        case .home:       combo = KeyCombo(keyCode: 53, modifiers: .command, key: "Esc")
        case .back:       combo = KeyCombo(keyCode: 51, modifiers: [.control, .command], key: "⌫")
        case .settings:   combo = KeyCombo(keyCode: 43, modifiers: .command, key: ",")
        case .gridLayout: combo = KeyCombo(keyCode: 18, modifiers: .command, key: "1")
        case .rowsLayout: combo = KeyCombo(keyCode: 19, modifiers: .command, key: "2")
        }
        return ShortcutSetting(enabled: true, combo: combo, ignoreWhileTyping: false)
    }
}
