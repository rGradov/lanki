import AppKit
import SwiftUI

/// Coordinates the global shortcut with the capture-and-popup flow.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private let settings = SettingsStore.shared
    private var didConfigure = false
    private var didShowPermissionPopupThisSession = false
    private var isTriggering = false
    private var lastTrigger = Date.distantPast

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        HotkeyService.shared.setHandler { [weak self] in
            self?.trigger()
        }
        update(with: settings)
        NSLog("Lanki: running at \(AccessibilityService.shared.runningAppPath), AX trusted=\(AccessibilityService.shared.isTrusted)")
    }

    func update(with settings: SettingsStore) {
        if settings.shortcutEnabled {
            HotkeyService.shared.register(settings.hotkey)
        } else {
            HotkeyService.shared.unregister()
        }
    }

    func trigger() {
        // Clipboard capture pumps the run loop, which can deliver the same
        // hotkey again and open a second panel on top of the first.
        let now = Date()
        guard !isTriggering, now.timeIntervalSince(lastTrigger) > 0.35 else { return }
        isTriggering = true
        lastTrigger = now
        defer { isTriggering = false }

        // Capture FIRST while the source app still has focus.
        // Do not dismiss beforehand — that can reshuffle key windows.
        let point = AccessibilityService.shared.mouseLocation
        let trusted = AccessibilityService.shared.isTrusted
        let text = AccessibilityService.shared
            .selectedText(useClipboardFallback: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let text, !text.isEmpty {
            showLookup(for: text, at: point)
            return
        }

        // A pinned card stays on screen when the shortcut finds nothing.
        if PopupWindowService.shared.isPinned { return }

        if !trusted {
            showPermissionHelp(at: point)
            return
        }

        showEmptySelection(at: point)
    }

    private func showLookup(for text: String, at point: NSPoint) {
        let viewModel = PopupViewModel(selectedText: text, services: .shared)
        let popup = PopupWindowService.shared
        popup.show(at: point, appearance: settings.appearance) {
            PopupView(
                viewModel: viewModel,
                isPinned: popup.isPinned,
                onPinChange: { popup.setPinned($0) },
                onClose: { popup.forceDismiss() }
            )
        }
    }

    private func showEmptySelection(at point: NSPoint) {
        PopupWindowService.shared.show(at: point, appearance: settings.appearance) {
            EmptySelectionView(clipboardFallbackEnabled: settings.useClipboardFallback) {
                PopupWindowService.shared.dismiss()
            }
        }
    }

    private func showPermissionHelp(at point: NSPoint) {
        guard !didShowPermissionPopupThisSession else {
            showEmptySelection(at: point)
            return
        }
        didShowPermissionPopupThisSession = true

        let path = AccessibilityService.shared.runningAppPath
        PopupWindowService.shared.show(at: point, appearance: settings.appearance) {
            PermissionNeededView(
                appPath: path,
                onOpenSettings: {
                    AccessibilityService.shared.requestPermissionIfNeeded()
                    AccessibilityService.shared.openAccessibilitySettings()
                },
                onClose: {
                    PopupWindowService.shared.dismiss()
                }
            )
        }
    }
}
