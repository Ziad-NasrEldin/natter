import NatterCore
import SwiftUI

struct HotKeyRecorderControl: View {
    @Bindable var store: DictationStore

    var body: some View {
        Button(action: toggleRecording) {
            Text(store.isRecordingHotKey ? "Press a key…" : store.selectedHotKey.label)
                .frame(minWidth: 128)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(store.isRecordingHotKey ? Theme.Colour.accent : nil)
        .help(store.isRecordingHotKey
            ? "Press a key or combination. Escape cancels."
            : "Click, then press any key or combination")
        .accessibilityLabel("Dictation key")
        .accessibilityValue(
            store.isRecordingHotKey ? "Recording" : store.selectedHotKey.label
        )
        .contextMenu {
            Button("Reset to Right Option") {
                store.select(.defaultDictation)
            }
        }
    }

    private func toggleRecording() {
        if store.isRecordingHotKey {
            store.cancelHotKeyRecording()
        } else {
            store.beginHotKeyRecording()
        }
    }
}
