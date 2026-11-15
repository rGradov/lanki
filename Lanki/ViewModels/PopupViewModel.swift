import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine

/// Drives the popup: fetches the definition + translation (+ image) for the
/// selected text and handles pushing the resulting card to Anki.
@MainActor
final class PopupViewModel: ObservableObject {

    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    @Published var word: String
    @Published var pronunciation: String?
    @Published var partOfSpeech: String?
    @Published var definition: String = ""
    @Published var example: String = ""
    @Published var synonyms: String = ""
    @Published var translation: String = ""
    @Published var imageURL: URL?
    @Published var audioURL: URL?
    /// True while a Pexels URL is in flight (shimmer shown in the popup).
    @Published var isLoadingImage = false
    /// True only while the definition request is still in flight. The card can
    /// already show a translation; Add to Anki stays disabled until this ends,
    /// including when the dictionary returns nothing.
    @Published var isLoadingDefinition = false

    @Published var deck: String
    @Published var decks: [String]
    /// Provider used for the translation currently shown on this card.
    @Published var provider: TranslationProvider

    @Published var loadState: LoadState = .loading
    @Published var saveState: SaveState = .idle
    @Published var isRefreshingTranslation = false
    @Published var refreshError: String?
    @Published var isDropTargeted = false
    @Published var imageDropError: String?
    /// True when the current card was served from the on-disk lookup cache.
    @Published var servedFromCache = false

    private let services: ServiceContainer
    private let settings: SettingsStore
    private let cache: LookupCacheService

    private let cardID = UUID()
    private let createdAt = Date()
    private var committedWord: String
    private var committedTranslation = ""
    private var committedDefinition = ""
    private var committedSynonyms = ""
    private var didEditSynonyms = false
    private var persistChain: Task<Void, Never>?
    /// Bumped when a drop produces an image, so a slower URL fallback cannot overwrite it.
    private var dropGeneration = 0
    private var imageRemoved = false

    init(selectedText: String, services: ServiceContainer) {
        self.services = services
        self.settings = services.settings
        self.cache = services.cache
        self.word = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.committedWord = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deck = services.settings.deckName
        self.decks = [services.settings.deckName]
        self.provider = services.settings.translationProvider
        self.committedTranslation = ""
    }

    var sourceLanguage: Language { settings.sourceLang }
    var targetLanguage: Language { settings.targetLang }
    var imagesEnabled: Bool { settings.enableImages }

    // MARK: - Loading

    func load() async {
        loadState = .loading
        servedFromCache = false
        isLoadingImage = false
        Task { await loadDecks() }

        if applyCacheIfAvailable() {
            loadState = .loaded
            servedFromCache = true
            services.history.upsert(currentCard(status: .translated))
            if settings.enableImages, imageURL == nil, !imageRemoved {
                await loadImage()
                persistCache()
            }
            return
        }

        switch await fetchTranslation() {
        case .success(let trans) where !trans.isEmpty:
            translation = trans
            committedTranslation = trans
        case .failure(let error) where provider.isLocal:
            loadState = .failed(error.localizedDescription)
            return
        default:
            loadState = .failed("Couldn't translate this word.")
            return
        }
        loadState = .loaded
        services.history.upsert(currentCard(status: .translated))

        isLoadingDefinition = true
        let definitionTask = Task { await fetchDefinition() }

        if settings.enableImages {
            Task {
                await self.loadImage()
                self.persistCache()
            }
        }

        applyDefinition(await definitionTask.value)
        isLoadingDefinition = false
        services.history.upsert(currentCard(status: .translated))
        persistCache()
    }

    @discardableResult
    private func applyCacheIfAvailable() -> Bool {
        guard let cached = cache.cachedLookup(
            word: word,
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            provider: provider.rawValue
        ) else { return false }

        let cleanedDefinition = DictionaryCopy.cleanedDefinition(cached.definition ?? "")
        let cleanedTranslation = TranslationStyle.normalize(cached.translation ?? "")
        guard TranslationStyle.isPlausibleTranslation(
            cleanedTranslation,
            language: settings.targetLanguage,
            sourceText: word
        ) else { return false }

        pronunciation = cached.pronunciation
        partOfSpeech = cached.partOfSpeech
        definition = cleanedDefinition
        committedDefinition = cleanedDefinition
        example = cached.example ?? ""
        synonyms = cached.synonyms ?? ""
        committedSynonyms = synonyms
        translation = cleanedTranslation
        committedTranslation = cleanedTranslation

        imageRemoved = cached.imageRemoved ?? false
        if !imageRemoved, let localImage = cached.imageURL(cacheRoot: cache.rootURL),
           FileManager.default.fileExists(atPath: localImage.path) {
            imageURL = localImage
        } else if settings.enableImages, !imageRemoved {
            imageURL = cached.remoteImageURL
        }

        if let localAudio = cached.audioURL(cacheRoot: cache.rootURL),
           FileManager.default.fileExists(atPath: localAudio.path) {
            audioURL = localAudio
        } else {
            audioURL = cached.remoteAudioURL
        }

        return true
    }

    private func applyDefinition(_ def: WordDefinition?) {
        guard let def else { return }
        pronunciation = def.pronunciation
        partOfSpeech = def.partOfSpeech
        definition = DictionaryCopy.cleanedDefinition(def.definition)
        committedDefinition = definition
        example = def.examples.first ?? ""
        if !didEditSynonyms {
            synonyms = def.synonyms.joined(separator: ", ")
            committedSynonyms = synonyms
        }
        audioURL = def.audioURL
    }

    private func loadImage() async {
        guard !imageRemoved else { return }
        let generation = dropGeneration
        isLoadingImage = true
        let url = await services.images.firstImageURL(for: word)
        // A manual drop or removal wins over an earlier network request.
        guard generation == dropGeneration else { return }
        imageURL = url
        isLoadingImage = false
    }

    func clearImage() {
        dropGeneration += 1
        imageRemoved = true
        imageURL = nil
        isLoadingImage = false
        imageDropError = nil
        services.history.upsert(currentCard(status: .translated))
        persistCache()
    }

    /// Writes edited card text into history and the lookup cache.
    /// Skips the write when nothing changed.
    func commitWordEdit() {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { word = committedWord; return }
        word = trimmed
        guard word != committedWord else { return }
        // Pronunciation belongs to the original spelling; fall back to TTS.
        pronunciation = nil
        audioURL = nil
        commitFieldEdit(\.word, committed: \.committedWord)
    }

    func commitTranslationEdit() {
        commitFieldEdit(\.translation, committed: \.committedTranslation)
    }

    func commitDefinitionEdit() {
        commitFieldEdit(\.definition, committed: \.committedDefinition)
    }

    func commitSynonymsEdit() {
        // Manual text (including an empty value) wins over a pending lookup.
        didEditSynonyms = true
        commitFieldEdit(\.synonyms, committed: \.committedSynonyms)
    }

    private func commitFieldEdit(
        _ value: ReferenceWritableKeyPath<PopupViewModel, String>,
        committed: ReferenceWritableKeyPath<PopupViewModel, String>
    ) {
        let trimmed = self[keyPath: value].trimmingCharacters(in: .whitespacesAndNewlines)
        self[keyPath: value] = trimmed
        guard trimmed != self[keyPath: committed] else { return }
        self[keyPath: committed] = trimmed
        services.history.upsert(currentCard(status: .translated))
        persistCache()
    }

    func loadDecks() async {
        guard let names = try? await services.anki.deckNames(), !names.isEmpty else { return }
        var combined = names
        if !combined.contains(deck) {
            combined.insert(deck, at: 0)
        }
        decks = combined
    }

    /// Accepts a browser image drag: raw image bytes, a local file, or an http(s) URL.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let hasImage = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        let hasFile = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        let hasURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        guard hasImage || hasFile || hasURL else { return false }

        dropGeneration += 1
        let generation = dropGeneration

        if hasImage {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, !data.isEmpty else { return }
                let bytes = data
                Task { @MainActor in
                    guard self.dropGeneration == generation else { return }
                    if self.importImage(data: bytes) {
                        self.dropGeneration += 1
                    }
                }
            }
        }
        if hasFile {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.url(from: item) else { return }
                Task { @MainActor in
                    guard self.dropGeneration == generation else { return }
                    if url.isFileURL {
                        if self.importImage(from: url) { self.dropGeneration += 1 }
                    } else {
                        await self.importRemoteImage(from: url, generation: generation)
                    }
                }
            }
        }
        if hasURL {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                guard let url = Self.url(from: item) else { return }
                Task { @MainActor in
                    await self.importRemoteImage(from: url, generation: generation)
                }
            }
        }
        return true
    }

    private func persistCache() {
        let image = imageURL
        let audio = audioURL
        let removedImage = imageRemoved
        let snapshot = (
            word: word,
            source: settings.sourceLanguage,
            target: settings.targetLanguage,
            provider: provider.rawValue,
            pronunciation: pronunciation,
            partOfSpeech: partOfSpeech,
            definition: definition.isEmpty ? nil : definition,
            example: example.isEmpty ? nil : example,
            synonyms: synonyms.isEmpty ? nil : synonyms,
            translation: translation.isEmpty ? nil : translation
        )
        let previous = persistChain
        let task = Task { @MainActor in
            await previous?.value
            await cache.store(
                word: snapshot.word,
                source: snapshot.source,
                target: snapshot.target,
                provider: snapshot.provider,
                pronunciation: snapshot.pronunciation,
                partOfSpeech: snapshot.partOfSpeech,
                definition: snapshot.definition,
                example: snapshot.example,
                synonyms: snapshot.synonyms,
                translation: snapshot.translation,
                remoteImageURL: image,
                remoteAudioURL: audio,
                imageRemoved: removedImage
            )
        }
        persistChain = task
        Task { @MainActor in
            await task.value
            guard persistChain == task else { return }
            if let cached = cache.cachedLookup(
                word: snapshot.word,
                source: snapshot.source,
                target: snapshot.target,
                provider: snapshot.provider
            ) {
                if !imageRemoved, let localImage = cached.imageURL(cacheRoot: cache.rootURL),
                   FileManager.default.fileExists(atPath: localImage.path) {
                    imageURL = localImage
                }
                if let localAudio = cached.audioURL(cacheRoot: cache.rootURL),
                   FileManager.default.fileExists(atPath: localAudio.path) {
                    audioURL = localAudio
                }
            }
        }
    }

    private func fetchDefinition() async -> WordDefinition? {
        try? await services.dictionary.lookup(word)
    }

    /// Asks MyMemory, then Lingva, without Opus-MT or Apple Translation.
    func refreshTranslation() async {
        guard !isRefreshingTranslation else { return }
        isRefreshingTranslation = true
        refreshError = nil
        defer { isRefreshingTranslation = false }

        do {
            let text = try await services.translation.translateFromNetwork(
                word,
                from: settings.sourceLanguage,
                to: settings.targetLanguage,
                preferringDifferentFrom: translation
            )
            translation = text
            committedTranslation = text
            services.history.upsert(currentCard(status: .translated))
            persistCache()
        } catch {
            refreshError = error.localizedDescription
        }
    }

    private func fetchTranslation() async -> Result<String, Error> {
        do {
            let text = try await services.translation.translate(
                word,
                from: settings.sourceLanguage,
                to: settings.targetLanguage,
                using: provider
            )
            return .success(text)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Saving

    func currentCard(status: CardStatus) -> WordCard {
        WordCard(
            id: cardID,
            word: word,
            pronunciation: pronunciation,
            definition: definition.isEmpty ? nil : definition,
            partOfSpeech: partOfSpeech,
            examples: example.isEmpty ? [] : [example],
            synonyms: synonyms.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            translation: translation.isEmpty ? nil : translation,
            imageURL: imageURL,
            audioURL: audioURL,
            createdAt: createdAt,
            status: status
        )
    }

    func addToAnki() async {
        guard !isLoadingDefinition, saveState != .saving else { return }
        saveState = .saving

        var card = currentCard(status: .addedToAnki)
        // Ensure the card carries audio: prefer the real clip, otherwise render
        // a spoken WAV with the system voice so the card is never silent.
        card.audioURL = await preparedAudioURL()
        do {
            try await services.anki.addCard(card, deck: deck)
            services.history.upsert(card)
            settings.deckName = deck
            saveState = .saved
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                // dismiss() keeps a pinned card open. Adding the word is done,
                // so drop the pin and close.
                PopupWindowService.shared.forceDismiss()
                self?.saveState = .idle
            }
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    private func importImage(from url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            imageDropError = "Couldn't read that image."
            return false
        }
        return importImage(data: data)
    }

    private func importRemoteImage(from url: URL, generation: Int) async {
        guard dropGeneration == generation else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard dropGeneration == generation else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                imageDropError = "Couldn't download that image."
                return
            }
            if importImage(data: data) {
                dropGeneration += 1
            }
        } catch {
            guard dropGeneration == generation else { return }
            imageDropError = "Couldn't download that image."
        }
    }

    @discardableResult
    private func importImage(data: Data) -> Bool {
        guard let jpeg = Self.jpegData(from: data) else {
            imageDropError = "That file isn't an image."
            return false
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("lanki-popup-\(UUID().uuidString).jpg")
        do {
            try jpeg.write(to: dest, options: .atomic)
            imageRemoved = false
            imageURL = dest
            isLoadingImage = false
            imageDropError = nil
            services.history.upsert(currentCard(status: .translated))
            persistCache()
            return true
        } catch {
            imageDropError = "Couldn't save the image."
            return false
        }
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
                ?? String(data: data, encoding: .utf8).flatMap(URL.init(string:))
        }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private static func jpegData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return nil
        }
        return jpeg
    }

    /// Returns a usable audio file for the Anki card: an existing local clip if
    /// one is cached, otherwise a freshly rendered TTS `.wav`. Falls back to the
    /// remote URL (AnkiConnect can fetch it) if synthesis fails.
    private func preparedAudioURL() async -> URL? {
        if let audioURL, audioURL.isFileURL,
           FileManager.default.fileExists(atPath: audioURL.path) {
            return audioURL
        }
        if let wav = await services.speech.synthesizeWAV(text: word, language: settings.sourceLanguage) {
            return wav
        }
        return audioURL // remote clip, if any
    }
}
