import SwiftUI

/// Shown when the hotkey fired but no selection could be read.
struct EmptySelectionView: View {
    let clipboardFallbackEnabled: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("No selection")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("Highlight a word or sentence first, then press the shortcut.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !clipboardFallbackEnabled {
                Text("If this happens in VS Code / Telegram / other Electron apps, enable “Clipboard fallback” in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 340)
        .popupGlassCard()
        .focusEffectDisabled()
    }
}
