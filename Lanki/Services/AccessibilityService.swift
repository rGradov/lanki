import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reads the currently selected text from the frontmost app.
/// 1) Accessibility selected-text attributes
/// 2) Safe ⌘C clipboard capture (only if pasteboard actually changes)
final class AccessibilityService {
    static let shared = AccessibilityService()
    private init() {}

    private var didPromptThisSession = false
    private var didOpenSettingsThisSession = false

    // MARK: - Permissions

    var isTrusted: Bool { AXIsProcessTrusted() }
    var runningAppPath: String { Bundle.main.bundlePath }

    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        if isTrusted { return true }
        guard !didPromptThisSession else { return isTrusted }
        didPromptThisSession = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettingsIfNeeded() {
        guard !didOpenSettingsThisSession else { return }
        didOpenSettingsThisSession = true
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Selection

    var mouseLocation: NSPoint { NSEvent.mouseLocation }

    /// Captures the current selection.
    /// - Parameter useClipboardFallback: when true (default path), synthesizes ⌘C
    ///   after modifiers are released. Never returns stale clipboard contents.
    func selectedText(useClipboardFallback: Bool = true) -> String? {
        if let text = selectedTextViaAX()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        guard useClipboardFallback else { return nil }
        return selectedTextViaClipboard()
    }

    // MARK: - AX

    private func selectedTextViaAX() -> String? {
        if let el = systemWideFocusedElement(),
           let text = selectedTextWalkingHierarchy(from: el) {
            return text
        }
        if let el = frontmostAppFocusedElement(),
           let text = selectedTextWalkingHierarchy(from: el) {
            return text
        }
        if let el = focusedAppThenFocusedElement(),
           let text = selectedTextWalkingHierarchy(from: el) {
            return text
        }
        return nil
    }

    private func systemWideFocusedElement() -> AXUIElement? {
        copyElement(AXUIElementCreateSystemWide(), attribute: kAXFocusedUIElementAttribute as CFString)
    }

    private func frontmostAppFocusedElement() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return copyElement(AXUIElementCreateApplication(pid), attribute: kAXFocusedUIElementAttribute as CFString)
    }

    private func focusedAppThenFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let app = copyElement(system, attribute: kAXFocusedApplicationAttribute as CFString) else { return nil }
        return copyElement(app, attribute: kAXFocusedUIElementAttribute as CFString)
    }

    private func copyElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func selectedTextWalkingHierarchy(from element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let el = current else { break }
            if let text = selectedTextAttributes(from: el) { return text }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private func selectedTextAttributes(from element: AXUIElement) -> String? {
        var selected: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let text = selected as? String, !text.isEmpty {
            return text
        }

        var rangeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let axRange = rangeValue {
            var text: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                axRange,
                &text
            ) == .success, let string = text as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    // MARK: - Clipboard (⌘C)

    private func selectedTextViaClipboard() -> String? {
        // Critical: our hotkey is ⌘⇧A. If Shift/Cmd are still held, posting ⌘C
        // becomes ⌘⇧C and copy never happens → perpetual "No selection".
        waitForModifierKeysReleased(timeout: 1.0)

        let pasteboard = NSPasteboard.general
        let previousItems = snapshotPasteboard(pasteboard)
        let previousChangeCount = pasteboard.changeCount
        let previousString = pasteboard.string(forType: .string)

        synthesizeCopy()

        let deadline = Date().addingTimeInterval(0.55)
        while pasteboard.changeCount == previousChangeCount && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.015))
        }

        // Pasteboard must actually change — never return pre-existing clipboard text.
        guard pasteboard.changeCount != previousChangeCount else {
            return nil
        }

        let copied = pasteboard.string(forType: .string)

        restorePasteboard(pasteboard, items: previousItems)

        guard let copied else { return nil }
        let trimmed = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Extra guard: if content is identical and we somehow raced, still OK if
        // changeCount moved (user re-copied the same string). Allow it.
        _ = previousString
        return trimmed
    }

    /// Poll until ⌘⌥⌃⇧ are up so synthesized ⌘C is not polluted by Shift etc.
    private func waitForModifierKeysReleased(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let mods = NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
            if mods.isEmpty { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [NSPasteboardItem]?) {
        guard let items else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    private func synthesizeCopy() {
        // Prefer hidSystemState — more reliable for injecting into other apps.
        let source = CGEventSource(stateID: .hidSystemState)
            ?? CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        // Session tap first, then HID as backup.
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
