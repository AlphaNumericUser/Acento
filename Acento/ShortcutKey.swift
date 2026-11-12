import AppKit
import Carbon

// Stored modifiers use Carbon's flags, plus a private flag for Fn combinations.
nonisolated enum ShortcutKey {
    static let fnModifier = 1 << 23
    static let modifierNames: [UInt16: String] = [
        54: "Right Command", 55: "Left Command", 56: "Left Shift",
        60: "Right Shift", 58: "Left Option", 61: "Right Option",
        59: "Left Control", 62: "Right Control", 63: "Fn", 57: "Caps Lock"
    ]
    static let deviceMasks: [UInt16: UInt] = [
        54: 0x10, 55: 0x08, 56: 0x02, 60: 0x04,
        58: 0x20, 61: 0x40, 59: 0x01, 62: 0x2000,
        63: NSEvent.ModifierFlags.function.rawValue, 57: NSEvent.ModifierFlags.capsLock.rawValue
    ]

    static func modifiers(_ flags: NSEvent.ModifierFlags, excluding key: UInt16? = nil) -> Int {
        var result = 0
        if flags.contains(.control), key != 59, key != 62 { result |= Int(controlKey) }
        if flags.contains(.option), key != 58, key != 61 { result |= Int(optionKey) }
        if flags.contains(.shift), key != 56, key != 60 { result |= Int(shiftKey) }
        if flags.contains(.command), key != 54, key != 55 { result |= Int(cmdKey) }
        return result
    }

    static func capturedModifiers(_ event: NSEvent) -> Int {
        var result = modifiers(event.modifierFlags, excluding: modifierNames[event.keyCode] == nil ? nil : event.keyCode)
        // macOS marks function/navigation keys with .function even without Fn.
        if event.modifierFlags.contains(.function), event.keyCode != 63,
           !specialKeys.keys.contains(event.keyCode) { result |= fnModifier }
        return result
    }

    static func label(key: UInt16, modifiers: Int, characters: String) -> String {
        var prefix = ""
        if modifiers & Int(controlKey) != 0 { prefix += "⌃ + " }
        if modifiers & Int(optionKey) != 0 { prefix += "⌥ + " }
        if modifiers & Int(shiftKey) != 0 { prefix += "⇧ + " }
        if modifiers & Int(cmdKey) != 0 { prefix += "⌘ + " }
        if modifiers & fnModifier != 0 { prefix += "Fn + " }
        let name = modifierNames[key] ?? specialKeys[key] ?? (
            characters.isEmpty || characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                ? "Key \(key)" : characters.uppercased())
        return prefix + name
    }

    static func displayLabel(_ label: String, locale: Locale) -> String {
        label.components(separatedBy: " + ").map { L10n.text($0, locale: locale) }.joined(separator: " + ")
    }

    static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 53: "Escape",
        51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down", 114: "Help",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20"
    ]
}
