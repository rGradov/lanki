import SwiftUI

/// Shown near the cursor when Accessibility is not (yet) trusted for this binary.
struct PermissionNeededView: View {
    let appPath: String
    var onOpenSettings: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accessibility required")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("macOS granted permission to a different copy of Lanki, or this process needs a restart after enabling the toggle.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(appPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)

            Text("1. Remove every Lanki from Accessibility\n2. Click Enable below and turn the toggle ON for this app\n3. Quit Lanki completely and open it again")
                .font(.system(size: 12))
                .foregroundStyle(.primary)

            Button(action: onOpenSettings) {
                Text("Open Accessibility Settings")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(18)
        .frame(width: 360)
        .popupGlassCard()
        .focusEffectDisabled()
    }
}
