import SwiftUI
import AppKit

/// A control that records a new global shortcut. Click to start recording, then
/// press the desired key combination.
struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey
    var onChange: (Hotkey) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            toggleRecording()
        } label: {
            HStack {
                Text(isRecording ? "Press keys…" : hotkey.displayString)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(isRecording ? Theme.accent : Theme.primaryText)
                Spacer()
                Image(systemName: isRecording ? "record.circle" : "keyboard")
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(minWidth: 150)
            .fieldStyle(radius: 10)
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require at least one non-shift modifier to avoid trivial shortcuts.
            guard !mods.isEmpty else { return nil }
            let new = Hotkey(keyCode: UInt32(event.keyCode), modifierFlags: mods.rawValue)
            hotkey = new
            onChange(new)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
