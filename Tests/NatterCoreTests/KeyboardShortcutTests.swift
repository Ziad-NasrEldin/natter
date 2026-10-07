import Testing
@testable import NatterCore

@Test func modeCycleShortcutRequiresCommandShiftM() {
    let shortcut = DictationShortcut.defaultModeCycle

    #expect(shortcut.matches(
        keyCode: 46,
        modifiers: [.command, .shift]
    ))
    #expect(!shortcut.matches(
        keyCode: 48,
        modifiers: []
    ))
    #expect(!shortcut.matches(
        keyCode: 46,
        modifiers: []
    ))
    #expect(!shortcut.matches(
        keyCode: 46,
        modifiers: [.command, .shift, .option]
    ))
}

@Test func dictationShortcutLabelsDescribeKeysAndCombinations() {
    #expect(DictationShortcut.defaultDictation.label == "Right Option")
    #expect(DictationShortcut(ModifierHotKey.rightControl).label == "Right Control")
    #expect(DictationShortcut(keyCode: 105, modifiers: []).label == "F13")
    #expect(
        DictationShortcut(keyCode: 2, modifiers: [.command, .shift]).label == "⇧⌘D"
    )
    #expect(DictationShortcut.defaultDictation.isModifierOnly)
    #expect(!DictationShortcut(keyCode: 49, modifiers: []).isModifierOnly)
}

@Test func hotKeyRecordingCapturesModifierOnlyKeysOnRelease() {
    var session = HotKeyRecordingSession()

    #expect(
        session.observeModifier(keyCode: DictationKeyCode.rightOption, isDown: true)
            == .listening
    )
    #expect(
        session.observeModifier(keyCode: DictationKeyCode.rightOption, isDown: false)
            == .captured(.defaultDictation)
    )
}

@Test func hotKeyRecordingCapturesKeyCombinations() {
    var session = HotKeyRecordingSession()

    #expect(
        session.observeModifier(keyCode: DictationKeyCode.leftCommand, isDown: true)
            == .listening
    )
    #expect(
        session.observeKeyDown(keyCode: 2, modifiers: [.command])
            == .captured(DictationShortcut(keyCode: 2, modifiers: [.command]))
    )
}

@Test func hotKeyRecordingEscapeCancelsAndModeCycleIsRejected() {
    var session = HotKeyRecordingSession()

    #expect(session.observeKeyDown(keyCode: DictationKeyCode.escape, modifiers: []) == .cancelled)
    #expect(
        session.observeKeyDown(keyCode: 46, modifiers: [.command, .shift]) == .rejected
    )
}

@Test func hotKeyRecordingDoesNotTreatChordedModifiersAsALoneKey() {
    var session = HotKeyRecordingSession()

    #expect(
        session.observeModifier(keyCode: DictationKeyCode.leftCommand, isDown: true)
            == .listening
    )
    #expect(
        session.observeModifier(keyCode: DictationKeyCode.leftShift, isDown: true)
            == .listening
    )
    #expect(
        session.observeModifier(keyCode: DictationKeyCode.leftShift, isDown: false)
            == .listening
    )
    #expect(
        session.observeModifier(keyCode: DictationKeyCode.leftCommand, isDown: false)
            == .listening
    )
}
