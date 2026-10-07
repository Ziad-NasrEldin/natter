public enum HotKeyRecordingOutcome: Equatable, Sendable {
    case listening
    case captured(DictationShortcut)
    case cancelled
    case rejected
}

public struct HotKeyRecordingSession: Sendable {
    public static let conflictMessage =
        "Command-Shift-M is reserved for switching mode while listening."

    private var heldModifiers: Set<UInt16> = []
    private var groupModifiers: Set<UInt16> = []
    private var sawNonModifierKey = false

    public init() {}

    public mutating func reset() {
        heldModifiers = []
        groupModifiers = []
        sawNonModifierKey = false
    }

    public mutating func observeModifier(keyCode: UInt16, isDown: Bool) -> HotKeyRecordingOutcome {
        guard DictationKeyCode.isModifier(keyCode) else { return .listening }

        if keyCode == DictationKeyCode.capsLock {
            return validate(DictationShortcut(keyCode: keyCode, modifiers: []))
        }

        if isDown {
            if heldModifiers.isEmpty {
                groupModifiers = []
                sawNonModifierKey = false
            }
            heldModifiers.insert(keyCode)
            groupModifiers.insert(keyCode)
            return .listening
        }

        heldModifiers.remove(keyCode)
        guard heldModifiers.isEmpty else { return .listening }
        defer { beginGroup() }
        if !sawNonModifierKey, groupModifiers.count == 1, let only = groupModifiers.first {
            return validate(DictationShortcut(keyCode: only, modifiers: []))
        }
        return .listening
    }

    public mutating func observeKeyDown(
        keyCode: UInt16,
        modifiers: DictationShortcutModifiers
    ) -> HotKeyRecordingOutcome {
        if keyCode == DictationKeyCode.escape, modifiers.isEmpty {
            return .cancelled
        }
        guard !DictationKeyCode.isModifier(keyCode) else { return .listening }
        sawNonModifierKey = true
        return validate(
            DictationShortcut(
                keyCode: keyCode,
                modifiers: DictationShortcut.normalized(modifiers)
            )
        )
    }

    private mutating func beginGroup() {
        groupModifiers = []
        sawNonModifierKey = false
    }

    private func validate(_ shortcut: DictationShortcut) -> HotKeyRecordingOutcome {
        if shortcut.matches(.defaultModeCycle) {
            return .rejected
        }
        return .captured(shortcut)
    }
}
