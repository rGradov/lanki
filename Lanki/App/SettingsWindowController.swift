import AppKit
import SwiftUI

/// Owns a real NSWindow for preferences. The SwiftUI `Settings` scene is
/// unreliable for `LSUIElement` / accessory menu-bar apps — this always works.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        AppearanceManager.apply(SettingsStore.shared.appearance)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window, window.isVisible {
            applyChrome(to: window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView()
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Lanki Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 780, height: 560))
        window.minSize = NSSize(width: 700, height: 480)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .normal
        window.backgroundColor = NSColor(Theme.settingsCanvas)
        applyChrome(to: window)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyChrome(to window: NSWindow) {
        switch SettingsStore.shared.appearance {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }
        window.backgroundColor = NSColor(Theme.settingsCanvas)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard self.window?.isVisible != true else { return }
            let otherVisible = NSApp.windows.contains {
                $0 !== self.window && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is PopupPanel)
            }
            if !otherVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
