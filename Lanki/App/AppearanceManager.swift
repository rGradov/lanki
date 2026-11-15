import AppKit

/// Applies the user's chosen theme to the whole app (menu, settings window and
/// popup) so everything stays consistent.
enum AppearanceManager {
    @MainActor
    static func apply(_ appearance: AppAppearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // Keep any open Settings window in sync with the chosen theme.
        for window in NSApp.windows where window.title == "Lanki Settings" || window.title == "New Word" || window.titleVisibility == .hidden {
            switch appearance {
            case .system: window.appearance = nil
            case .light: window.appearance = NSAppearance(named: .aqua)
            case .dark: window.appearance = NSAppearance(named: .darkAqua)
            }
            window.backgroundColor = NSColor(Theme.settingsCanvas)
        }
    }
}
