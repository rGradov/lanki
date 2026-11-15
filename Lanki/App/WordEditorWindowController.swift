import AppKit
import SwiftUI

/// A real titled window for composing a card. Survives Cmd-Tab because the
/// app switches to a regular activation policy while it is open.
@MainActor
final class WordEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = WordEditorWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        AppearanceManager.apply(SettingsStore.shared.appearance)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window, window.isVisible {
            applyChrome(to: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = WordEditorView(viewModel: WordEditorViewModel(services: .shared))
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "New Word"
        window.setContentSize(NSSize(width: 540, height: 680))
        window.minSize = NSSize(width: 480, height: 560)
        window.center()
        window.isReleasedWhenClosed = true
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .normal
        window.backgroundColor = NSColor(Theme.settingsCanvas)
        applyChrome(to: window)

        self.window = window
        window.makeKeyAndOrderFront(nil)
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
        self.window = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let otherVisible = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled) && !($0 is PopupPanel)
            }
            if !otherVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
