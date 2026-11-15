import SwiftUI
import AppKit

@main
struct LankiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = SettingsStore.shared

    var body: some Scene {
        MenuBarExtra("Lanki", systemImage: "character.book.closed.fill") {
            MenuBarContent(settings: settings)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var updater = LankiUpdater.shared

    var body: some View {
        Text("Lanki – Language Assistant")

        Button("Create New Word…") {
            WordEditorWindowController.shared.show()
        }
        .keyboardShortcut("n", modifiers: .command)

        Button("Open Settings…") {
            SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        UpdateMenuItem(updater: updater)

        Toggle(isOn: $settings.shortcutEnabled) {
            Text("Enable Shortcut (\(settings.hotkey.displayString))")
        }
        .onChange(of: settings.shortcutEnabled) { _, _ in
            HotkeyManager.shared.update(with: settings)
        }

        Divider()

        Button("Quit Lanki") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

/// A dedicated view so this row re-renders when Sparkle's check state changes.
/// Becomes "Restart to Update to Lanki X.Y" once Sparkle has downloaded an
/// update and is waiting to install it on quit.
private struct UpdateMenuItem: View {
    @ObservedObject var updater: LankiUpdater

    var body: some View {
        if let version = updater.readyUpdateVersion {
            Button(LankiUpdater.restartTitle(forVersion: version)) {
                updater.restartToUpdate()
            }
        } else {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
