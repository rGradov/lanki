import AppKit
import Carbon.HIToolbox

/// Registers a single global hotkey using the Carbon Event Manager
/// (`RegisterEventHotKey`). This works system-wide without an event tap and is
/// the most reliable approach for a menu-bar utility.
final class HotkeyService {
    static let shared = HotkeyService()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var handler: (() -> Void)?
    private let signature: OSType = 0x4C4E4B49 // 'LNKI'
    private let hotKeyID: UInt32 = 1

    private init() {}

    /// The closure invoked (on the main queue) whenever the hotkey fires.
    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    /// Registers (or re-registers) `hotkey`. Safe to call repeatedly.
    func register(_ hotkey: Hotkey) {
        unregister()
        installEventHandlerIfNeeded()

        let eventID = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            eventID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("Lanki: failed to register hotkey (status \(status))")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
            var firedID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &firedID
            )
            if firedID.id == service.hotKeyID {
                DispatchQueue.main.async { service.handler?() }
            }
            return noErr
        }

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}
