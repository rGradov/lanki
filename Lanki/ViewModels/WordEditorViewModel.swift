import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Backing store for the “Create New Word” window — a full card the user can
/// fill in by hand (no shortcut required) and push to Anki.
@MainActor
final class WordEditorViewModel: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @Published var word = ""
    @Published var translation = ""
    @Published var pronunciation = ""
    @Published var partOfSpeech = ""
    @Published var definition = ""
    @Published var example = ""
    @Published var synonyms = ""
    @Published var imageURL: URL?
    @Published var audioURL: URL?
    @Published var deck: String
    @Published var decks: [String] = []

    @Published var isLookingUpPronunciation = false
    @Published var isLookingUpImage = false
    @Published var lookupError: String?
    @Published var saveState: SaveState = .idle
    @Published var isDropTargeted = false

    private let services: ServiceContainer
    private let settings: SettingsStore
    private var createdAt = Date()

    init(services: ServiceContainer) {
        self.services = services
        self.settings = services.settings
        self.deck = services.settings.deckName
        self.decks = [services.settings.deckName, "Default"].uniqued()
    }

    var sourceLanguage: Language { settings.sourceLang }
    var targetLanguage: Language { settings.targetLang }
    var imagesEnabled: Bool { settings.enableImages }

    var canSave: Bool {
        !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && saveState != .saving
    }

    func loadDecks() async {
        if let names = try? await services.anki.deckNames(), !names.isEmpty {
            var combined = names
            if !combined.contains(deck) { combined.insert(deck, at: 0) }
            decks = combined
        }
    }

    /// Fills IPA / audio (and empty definition fields) from the dictionary API.
    func lookupPronunciation() async {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isLookingUpPronunciation else { return }
        isLookingUpPronunciation = true
        lookupError = nil
        defer { isLookingUpPronunciation = false }

        guard let def = try? await services.dictionary.lookup(query) else {
            lookupError = "No pronunciation found for “\(query)”."
            return
        }

        if let ipa = def.pronunciation, !ipa.isEmpty {
            pronunciation = ipa
        }
        if let pos = def.partOfSpeech, partOfSpeech.isEmpty {
            partOfSpeech = pos
        }
        if definition.isEmpty {
            definition = DictionaryCopy.cleanedDefinition(def.definition)
        }
        if example.isEmpty {
            example = def.examples.first ?? ""
        }
        if synonyms.isEmpty {
            synonyms = def.synonyms.joined(separator: ", ")
        }
        if let clip = def.audioURL {
            audioURL = clip
        }

        if pronunciation.isEmpty && audioURL == nil {
            lookupError = "Dictionary had no IPA or audio for this word."
        }
    }

    func lookupImage() async {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isLookingUpImage else { return }
        isLookingUpImage = true
        lookupError = nil
        defer { isLookingUpImage = false }

        guard let url = await services.images.firstImageURL(for: query) else {
            lookupError = "No image found. Add a Pexels API key in Settings, or drop a file."
            return
        }
        imageURL = url
    }

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose an image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(from: url)
    }

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = {
                    if let url = item as? URL { return url }
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                            ?? String(data: data, encoding: .utf8).flatMap(URL.init(string:))
                    }
                    return nil
                }()
                guard let url else { return }
                Task { @MainActor in self.importImage(from: url) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in self.importImage(data: data) }
            }
            return true
        }
        return false
    }

    func clearImage() {
        imageURL = nil
    }

    func addToAnki() async {
        guard canSave, saveState != .saving else { return }
        saveState = .saving
        lookupError = nil

        var card = currentCard(status: .addedToAnki)
        card.audioURL = await preparedAudioURL()
        do {
            try await services.anki.addCard(card, deck: deck)
            services.history.upsert(card)
            settings.deckName = deck
            saveState = .saved
            try? await Task.sleep(nanoseconds: 900_000_000)
            resetFormKeepingDeck()
            saveState = .idle
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func currentCard(status: CardStatus) -> WordCard {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranslation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPron = pronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDef = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExample = example.trimmingCharacters(in: .whitespacesAndNewlines)
        let syns = synonyms.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return WordCard(
            word: trimmedWord,
            pronunciation: trimmedPron.isEmpty ? nil : trimmedPron,
            definition: trimmedDef.isEmpty ? nil : trimmedDef,
            partOfSpeech: partOfSpeech.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            examples: trimmedExample.isEmpty ? [] : [trimmedExample],
            synonyms: syns,
            translation: trimmedTranslation.isEmpty ? nil : trimmedTranslation,
            imageURL: imageURL,
            audioURL: audioURL,
            createdAt: createdAt,
            status: status
        )
    }

    private func preparedAudioURL() async -> URL? {
        if let audioURL, audioURL.isFileURL,
           FileManager.default.fileExists(atPath: audioURL.path) {
            return audioURL
        }
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wav = await services.speech.synthesizeWAV(text: query, language: settings.sourceLanguage) {
            return wav
        }
        return audioURL
    }

    private func importImage(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        importImage(data: data, ext: ext)
    }

    private func importImage(data: Data, ext: String = "jpg") {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("lanki-editor-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: dest, options: .atomic)
            imageURL = dest
        } catch {
            lookupError = "Couldn’t save the image."
        }
    }

    private func resetFormKeepingDeck() {
        word = ""
        translation = ""
        pronunciation = ""
        partOfSpeech = ""
        definition = ""
        example = ""
        synonyms = ""
        imageURL = nil
        audioURL = nil
        lookupError = nil
        createdAt = Date()
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
