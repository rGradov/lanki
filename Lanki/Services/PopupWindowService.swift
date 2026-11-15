import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Owns the floating, borderless popup window. Handles positioning near the
/// cursor, appearance animation, and dismissing when the user clicks elsewhere.
final class PopupWindowService: NSObject, NSWindowDelegate {
    static let shared = PopupWindowService()

    private var window: PopupPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    /// Pinned cards ignore outside clicks and Escape, keep their origin, and
    /// stay above other windows. A later lookup replaces the text in place.
    private(set) var isPinned = false

    /// True while the translation field is focused. The panel may become key
    /// only for that interval so it does not steal focus from the app under it.
    private var translationEditing = false
    /// Armed by a press outside the card. A drag that enters the image drop
    /// zone sets `dropVisited` so the matching mouse-up does not close the card.
    private var outsidePress = false
    private var dropVisited = false
    /// True while `performWindowDrag` is tracking. That gesture ends with a
    /// mouse-up that must not count as a click outside the card.
    private var windowDragActive = false

    private override init() { super.init() }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Presents `content` in a popup anchored near the current mouse location.
    /// A pinned popup keeps its place and only swaps the card contents.
    func show<Content: View>(at point: NSPoint, appearance: AppAppearance, @ViewBuilder content: () -> Content) {
        if isPinned, let panel = window, panel.isVisible {
            install(AnyView(content()), in: panel, appearance: appearance, near: nil)
            panel.orderFrontRegardless()
            return
        }

        isPinned = false
        closeEveryPopup()

        let panel = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.onWindowClose = { [weak self] in self?.tearDownMonitors() }
        self.window = panel
        install(AnyView(content()), in: panel, appearance: appearance, near: point)
        panel.alphaValue = 1
        // Never makeKey — that steals focus from Safari/VS Code and breaks ⌘C capture.
        // No alpha animator: an in-flight animation orders the panel back on screen
        // after a later lookup has already replaced it.
        panel.orderFrontRegardless()
        panel.makeFirstResponder(nil)
        installMonitors()
    }

    /// Outside click and Escape. A pinned card stays put.
    func dismiss() {
        guard !isPinned else { return }
        closeEveryPopup()
    }

    /// Close button. Drops the pin so the next lookup starts unpinned.
    func forceDismiss() {
        isPinned = false
        closeEveryPopup()
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        guard let panel = window else { return }
        if pinned {
            tearDownMonitors()
            panel.level = .statusBar
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.level = .floating
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            if panel.isVisible {
                installMonitors()
            }
        }
        panel.orderFrontRegardless()
    }

    private func install(_ root: AnyView, in panel: PopupPanel, appearance: AppAppearance, near point: NSPoint?) {
        let hosting = NSHostingView(rootView: root)
        // Borderless panels otherwise add a safe-area inset and, once the card
        // grows (image, definition), leave a second copy of the bottom edge.
        hosting.safeAreaRegions = []
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.applyAppearance(appearance)

        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = NSSize(width: 360, height: max(160, fitting.height))

        if let point {
            panel.setContentSize(size)
            positionWindow(panel, near: point, size: size)
        } else {
            // Keep the header where the user left it while the card changes height.
            let old = panel.frame
            let origin = NSPoint(x: old.origin.x, y: old.maxY - size.height)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            clampOnScreen(panel)
        }
    }

    /// Drops every popup panel, including one that AppKit has ordered back in
    /// while its SwiftUI content was still resizing.
    private func closeEveryPopup() {
        tearDownMonitors()
        window = nil
        let panels = NSApp.windows.compactMap { $0 as? PopupPanel }
        for panel in panels {
            panel.contentView = nil
            panel.orderOut(nil)
            panel.close()
        }
    }

    // MARK: - Keep on screen

    /// The popup grows as its content loads in. This fires on those size
    /// changes (not on user drags) and nudges the window back fully on-screen
    /// so the "Add to Anki" button is never clipped at the bottom.
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        clampOnScreen(window)
        // A transparent panel caches its shadow from the previous frame.
        // After the card grows, that cache shows up as a second button underneath.
        window.invalidateShadow()
    }

    private func clampOnScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var frame = window.frame

        if frame.maxY > visible.maxY - margin { frame.origin.y = visible.maxY - margin - frame.height }
        if frame.minY < visible.minY + margin { frame.origin.y = visible.minY + margin }
        if frame.maxX > visible.maxX - margin { frame.origin.x = visible.maxX - margin - frame.width }
        if frame.minX < visible.minX + margin { frame.origin.x = visible.minX + margin }

        if frame.origin != window.frame.origin {
            window.setFrameOrigin(frame.origin)
        }
    }

    // MARK: - Positioning

    private func positionWindow(_ window: NSWindow, near point: NSPoint, size: NSSize) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else {
            window.setFrameOrigin(point)
            return
        }
        let visible = screen.visibleFrame
        let gap: CGFloat = 14

        // Prefer below-and-right of the cursor.
        var origin = NSPoint(x: point.x + gap, y: point.y - size.height - gap)

        if origin.x + size.width > visible.maxX { origin.x = point.x - size.width - gap }
        if origin.x < visible.minX { origin.x = visible.minX + gap }
        if origin.y < visible.minY { origin.y = point.y + gap } // flip above cursor
        if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height - gap }

        window.setFrameOrigin(origin)
    }

    func setTranslationEditing(_ editing: Bool) {
        translationEditing = editing
        guard let panel = window else { return }
        panel.allowsKey = editing
        if editing {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

    /// Ends translation editing without closing the card. Returns true when
    /// an edit was in progress.
    @discardableResult
    func endTranslationEditing() -> Bool {
        guard translationEditing else { return false }
        setTranslationEditing(false)
        NotificationCenter.default.post(name: .lankiEndTranslationEdit, object: nil)
        return true
    }

    func noteDropTargeted(_ targeted: Bool) {
        if targeted { dropVisited = true }
    }

    func beginWindowDrag() {
        windowDragActive = true
        outsidePress = false
    }

    func endWindowDrag() {
        windowDragActive = false
        outsidePress = false
        dropVisited = false
        if let window { clampOnScreen(window) }
    }

    // MARK: - Dismiss-on-outside-click

    private static let pointerEvents: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp
    ]

    private func installMonitors() {
        outsidePress = false
        dropVisited = false

        // Dismiss on mouse-up, not mouse-down. A drag from the browser begins
        // with a click outside the card; closing on that click would remove
        // the drop target before the image arrives.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.pointerEvents) { [weak self] event in
            guard let self else { return }
            if Self.isMouseDown(event) {
                self.armOutsidePress()
            } else {
                self.handleMouseUp()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.pointerEvents) { [weak self] event in
            guard let self, let window = self.window else { return event }
            if Self.isMouseDown(event) {
                if event.window != window { self.armOutsidePress() }
            } else if event.window != window {
                self.handleMouseUp()
            } else if self.windowDragActive {
                self.endWindowDrag()
            } else {
                self.outsidePress = false
                self.dropVisited = false
            }
            return event
        }

        // The panel is key only while the translation field is focused.
        // Escape is observed here so it still works the rest of the time.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isPlainEscape(event) else { return }
            self?.handleEscape()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.isPlainEscape(event) else { return event }
            self.handleEscape()
            return nil
        }
    }

    private func armOutsidePress() {
        // A window-server drag may not deliver mouse-up. The next press ends it.
        if windowDragActive { endWindowDrag() }
        outsidePress = true
        dropVisited = false
    }

    private func handleMouseUp() {
        if windowDragActive {
            endWindowDrag()
            return
        }
        finishOutsidePress()
    }

    private func finishOutsidePress() {
        let shouldDismiss = outsidePress && !dropVisited
        outsidePress = false
        dropVisited = false
        if shouldDismiss { dismiss() }
    }

    private func handleEscape() {
        if endTranslationEditing() { return }
        dismiss()
    }

    private static func isMouseDown(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown || event.type == .rightMouseDown
    }

    private static func isPlainEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Escape) else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return mods.isDisjoint(with: [.command, .option, .control])
    }

    private func tearDownMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalMonitor = nil
        localMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }
}

extension Notification.Name {
    static let lankiEndTranslationEdit = Notification.Name("lankiEndTranslationEdit")
}

/// Grab surface behind the card. `performWindowDrag` keeps the pointer locked
/// to the window, which a SwiftUI drag cannot do once the window starts moving.
struct WindowDragHandle: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> WindowDragHandleView {
        let view = WindowDragHandleView()
        view.enabled = enabled
        return view
    }

    func updateNSView(_ view: WindowDragHandleView, context: Context) {
        view.enabled = enabled
    }
}

final class WindowDragHandleView: NSView {
    var enabled = true {
        didSet {
            if oldValue != enabled {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        enabled ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard enabled else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard enabled, !PopupWindowService.shared.isPinned, let window else { return }
        PopupWindowService.shared.beginWindowDrag()
        // Returns immediately; the window server tracks the drag. The matching
        // mouse-up (or the next outside click) ends it.
        window.performDrag(with: event)
    }
}

/// Borderless, always-on-top panel. It becomes key only while the translation
/// field is being edited (`allowsKey`), so a lookup does not steal focus.
final class PopupPanel: NSPanel {
    var onWindowClose: (() -> Void)?
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        // Native window shadow follows the rounded card's alpha mask, so it
        // stays rounded (a SwiftUI shadow would be clipped square).
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // .utilityWindow animates frame changes and leaves the old card on screen.
        animationBehavior = .none
        // Let materials sample the desktop behind the panel.
        if #available(macOS 10.14, *) {
            // no-op: clear + non-opaque already enables vibrancy sampling
        }
    }

    func applyAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system: self.appearance = nil
        case .light: self.appearance = NSAppearance(named: .aqua)
        case .dark: self.appearance = NSAppearance(named: .darkAqua)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if PopupWindowService.shared.endTranslationEditing() { return }
        PopupWindowService.shared.dismiss()
    }
}
