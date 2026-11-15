import Foundation
import Combine

/// Central, observable, persisted settings for the whole app.
/// Values are mirrored into `UserDefaults` on change.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let ankiEndpoint = "ankiEndpoint"
        static let deckName = "deckName"
        static let noteModelName = "noteModelName"
        static let ankiFieldMapping = "ankiFieldMapping"
        static let sourceLanguage = "sourceLanguage"
        static let targetLanguage = "targetLanguage"
        static let hotkey = "hotkey"
        static let shortcutEnabled = "shortcutEnabled"
        static let pexelsAPIKey = "pexelsAPIKey"
        static let translationAPIKey = "translationAPIKey"
        static let translationProvider = "translationProvider"
        static let lingvaEndpoint = "lingvaEndpoint"
        static let enableImages = "enableImages"
        static let appearance = "appearance"
        static let useClipboardFallback = "useClipboardFallback"
    }

    // MARK: - Anki
    @Published var ankiEndpoint: String { didSet { defaults.set(ankiEndpoint, forKey: Key.ankiEndpoint) } }
    @Published var deckName: String { didSet { defaults.set(deckName, forKey: Key.deckName) } }
    /// Anki note type / model name (e.g. "Flat").
    @Published var noteModelName: String { didSet { defaults.set(noteModelName, forKey: Key.noteModelName) } }
    /// How Lanki values map onto that note type's field names.
    @Published var ankiFieldMapping: AnkiFieldMapping { didSet { persistFieldMapping() } }

    // MARK: - Languages
    @Published var sourceLanguage: String { didSet { defaults.set(sourceLanguage, forKey: Key.sourceLanguage) } }
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: Key.targetLanguage) } }

    // MARK: - Shortcut
    @Published var hotkey: Hotkey { didSet { persistHotkey() } }
    @Published var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: Key.shortcutEnabled) } }

    // MARK: - API keys / images
    @Published var pexelsAPIKey: String { didSet { defaults.set(pexelsAPIKey, forKey: Key.pexelsAPIKey) } }
    @Published var translationAPIKey: String { didSet { defaults.set(translationAPIKey, forKey: Key.translationAPIKey) } }
    @Published var enableImages: Bool { didSet { defaults.set(enableImages, forKey: Key.enableImages) } }

    // MARK: - Translation provider
    @Published var translationProvider: TranslationProvider { didSet { defaults.set(translationProvider.rawValue, forKey: Key.translationProvider) } }
    @Published var lingvaEndpoint: String { didSet { defaults.set(lingvaEndpoint, forKey: Key.lingvaEndpoint) } }

    /// When true, fall back to synthesizing ⌘C if Accessibility cannot read the
    /// selection (needed for some Electron apps). Off by default — clipboard
    /// must never silently replace a real selection.
    @Published var useClipboardFallback: Bool { didSet { defaults.set(useClipboardFallback, forKey: Key.useClipboardFallback) } }

    // MARK: - Appearance
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }

    private init() {
        ankiEndpoint = defaults.string(forKey: Key.ankiEndpoint) ?? "http://localhost:8765"
        deckName = defaults.string(forKey: Key.deckName) ?? "Default"
        noteModelName = defaults.string(forKey: Key.noteModelName) ?? "Flat"
        if let data = defaults.data(forKey: Key.ankiFieldMapping),
           let decoded = try? JSONDecoder().decode(AnkiFieldMapping.self, from: data) {
            ankiFieldMapping = decoded
        } else {
            ankiFieldMapping = .default
        }
        sourceLanguage = defaults.string(forKey: Key.sourceLanguage) ?? "en"
        targetLanguage = defaults.string(forKey: Key.targetLanguage) ?? "ru"
        shortcutEnabled = defaults.object(forKey: Key.shortcutEnabled) as? Bool ?? true
        pexelsAPIKey = defaults.string(forKey: Key.pexelsAPIKey) ?? ""
        translationAPIKey = defaults.string(forKey: Key.translationAPIKey) ?? ""
        translationProvider = TranslationProvider(rawValue: defaults.string(forKey: Key.translationProvider) ?? "") ?? .myMemory
        lingvaEndpoint = defaults.string(forKey: Key.lingvaEndpoint) ?? "https://lingva.ml"
        enableImages = defaults.object(forKey: Key.enableImages) as? Bool ?? true
        // v1.1: clipboard fallback must stay on by default — AX alone fails in most apps,
        // and ⌘⇧ hotkeys previously broke synthesized ⌘C while Shift was still held.
        if defaults.object(forKey: "clipboardFallbackMigratedV11") == nil {
            defaults.set(true, forKey: Key.useClipboardFallback)
            defaults.set(true, forKey: "clipboardFallbackMigratedV11")
            useClipboardFallback = true
        } else {
            useClipboardFallback = defaults.object(forKey: Key.useClipboardFallback) as? Bool ?? true
        }
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system

        if let data = defaults.data(forKey: Key.hotkey),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            hotkey = decoded
        } else {
            hotkey = .default
        }
    }

    private func persistHotkey() {
        if let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: Key.hotkey)
        }
    }

    private func persistFieldMapping() {
        if let data = try? JSONEncoder().encode(ankiFieldMapping) {
            defaults.set(data, forKey: Key.ankiFieldMapping)
        }
    }

    var sourceLang: Language { Language.named(sourceLanguage) }
    var targetLang: Language { Language.named(targetLanguage) }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
}
