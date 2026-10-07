public struct DictationShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
    public static let function = Self(rawValue: 1 << 4)

    public var symbolPrefix: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        if contains(.function) { symbols += "Fn" }
        return symbols
    }
}

public struct DictationShortcut: Equatable, Hashable, Codable, Sendable {
    public let keyCode: UInt16
    public let modifiers: DictationShortcutModifiers

    public init(keyCode: UInt16, modifiers: DictationShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(_ hotKey: ModifierHotKey) {
        self.init(keyCode: hotKey.keyCode, modifiers: [])
    }

    public var isModifierOnly: Bool {
        modifiers.isEmpty && DictationKeyCode.isModifier(keyCode)
    }

    public var label: String {
        if isModifierOnly {
            return DictationKeyCode.displayName(for: keyCode)
        }
        let prefix = modifiers.symbolPrefix
        let key = DictationKeyCode.displayName(for: keyCode)
        return prefix.isEmpty ? key : prefix + key
    }

    public func matches(
        keyCode: UInt16,
        modifiers: DictationShortcutModifiers
    ) -> Bool {
        self.keyCode == keyCode
            && Self.normalized(self.modifiers) == Self.normalized(modifiers)
    }

    public static func normalized(
        _ modifiers: DictationShortcutModifiers
    ) -> DictationShortcutModifiers {
        var result = modifiers
        result.remove(.function)
        return result
    }

    public func matches(_ other: Self) -> Bool {
        matches(keyCode: other.keyCode, modifiers: other.modifiers)
    }

    /// Right Option. The historical default dictation key.
    public static let defaultDictation = Self(keyCode: DictationKeyCode.rightOption, modifiers: [])

    /// Command-Shift-M. Kept as one value so shortcut customization can replace
    /// the default without changing the event monitor or mode-cycling behavior.
    public static let defaultModeCycle = Self(
        keyCode: 46,
        modifiers: [.command, .shift]
    )
}

public enum DictationKeyCode: Sendable {
    public static let escape: UInt16 = 53
    public static let rightCommand: UInt16 = 54
    public static let leftCommand: UInt16 = 55
    public static let leftShift: UInt16 = 56
    public static let capsLock: UInt16 = 57
    public static let leftOption: UInt16 = 58
    public static let leftControl: UInt16 = 59
    public static let rightShift: UInt16 = 60
    public static let rightOption: UInt16 = 61
    public static let rightControl: UInt16 = 62
    public static let function: UInt16 = 63

    public static func isModifier(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case rightCommand, leftCommand, leftShift, capsLock, leftOption,
             leftControl, rightShift, rightOption, rightControl, function:
            true
        default:
            false
        }
    }

    public static func displayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "Return"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "Tab"
        case 49: "Space"
        case 50: "`"
        case 51: "Delete"
        case escape: "Escape"
        case rightCommand: "Right Command"
        case leftCommand: "Left Command"
        case leftShift: "Left Shift"
        case capsLock: "Caps Lock"
        case leftOption: "Left Option"
        case leftControl: "Left Control"
        case rightShift: "Right Shift"
        case rightOption: "Right Option"
        case rightControl: "Right Control"
        case function: "Globe / Fn"
        case 64: "F17"
        case 65: "Keypad ."
        case 67: "Keypad *"
        case 69: "Keypad +"
        case 71: "Keypad Clear"
        case 75: "Keypad /"
        case 76: "Keypad Enter"
        case 78: "Keypad -"
        case 79: "F18"
        case 80: "F19"
        case 81: "Keypad ="
        case 82: "Keypad 0"
        case 83: "Keypad 1"
        case 84: "Keypad 2"
        case 85: "Keypad 3"
        case 86: "Keypad 4"
        case 87: "Keypad 5"
        case 88: "Keypad 6"
        case 89: "Keypad 7"
        case 91: "Keypad 8"
        case 92: "Keypad 9"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 105: "F13"
        case 106: "F16"
        case 107: "F14"
        case 109: "F10"
        case 111: "F12"
        case 113: "F15"
        case 114: "Help"
        case 115: "Home"
        case 116: "Page Up"
        case 117: "Forward Delete"
        case 118: "F4"
        case 119: "End"
        case 120: "F2"
        case 121: "Page Down"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }
}
