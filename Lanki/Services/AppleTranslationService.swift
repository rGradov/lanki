import AppKit
import SwiftUI
import Translation

/// System on-device translation. Requires macOS 15 and an installed language pack.
final class AppleTranslationService: TranslationService {
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.empty }
        guard #available(macOS 15, *) else {
            throw TranslationError.api("Apple Translation requires macOS 15 or later.")
        }
        return try await AppleTranslationBridge.shared.translate(trimmed, from: source, to: target)
    }
}

@available(macOS 15.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    @Published var configuration: TranslationSession.Configuration?
    private var waiter: CheckedContinuation<String, Error>?
    private var pendingText: String?

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        switch status {
        case .installed:
            break
        case .supported:
            let fromName = Language.named(source).name
            let toName = Language.named(target).name
            throw TranslationError.api("Install the \(fromName) and \(toName) translation languages in System Settings → General → Language & Region → Translation Languages.")
        case .unsupported:
            throw TranslationError.api("Apple Translation does not support this language pair.")
        @unknown default:
            throw TranslationError.api("Apple Translation cannot check this language pair.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
            self.pendingText = text
            self.configuration = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard self.waiter != nil else { return }
                self.configuration = TranslationSession.Configuration(
                    source: sourceLanguage,
                    target: targetLanguage
                )
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let waiter = self.takeWaiter()?.waiter else { return }
                waiter.resume(throwing: TranslationError.api("Apple Translation timed out."))
            }
        }
    }

    func handle(_ session: TranslationSession) async {
        guard let pending = takeWaiter() else { return }
        do {
            let response = try await session.translate(pending.text)
            let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty else {
                pending.waiter.resume(throwing: TranslationError.empty)
                return
            }
            pending.waiter.resume(returning: translated)
        } catch {
            pending.waiter.resume(throwing: TranslationError.api(error.localizedDescription))
        }
    }

    private func takeWaiter() -> (text: String, waiter: CheckedContinuation<String, Error>)? {
        guard let waiter, let pendingText else { return nil }
        let captured = (pendingText, waiter)
        self.waiter = nil
        self.pendingText = nil
        return captured
    }
}

@available(macOS 15.0, *)
enum AppleTranslationHost {
    private static var window: NSWindow?

    static func install() {
        guard window == nil else { return }
        let hosting = NSHostingView(rootView: AppleTranslationHostView())
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        panel.orderFrontRegardless()
        window = panel
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationHostView: View {
    @ObservedObject private var bridge = AppleTranslationBridge.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.handle(session)
            }
    }
}
