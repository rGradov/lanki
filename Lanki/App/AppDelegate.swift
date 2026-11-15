import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppearanceManager.apply(SettingsStore.shared.appearance)
        HotkeyManager.shared.configure()
        // Start Sparkle up front so the once-a-day update check is scheduled
        // even if the user never opens Settings (a menu-bar app has no window).
        _ = LankiUpdater.shared
        if #available(macOS 15, *) {
            AppleTranslationHost.install()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
