import Foundation

/// Simple dependency container. Builds the concrete services and wires them to
/// the live settings so API keys / endpoints are always read fresh.
@MainActor
final class ServiceContainer {
    static let shared = ServiceContainer()

    let settings = SettingsStore.shared
    let history = HistoryStore.shared
    let cache = LookupCacheService.shared
    let speech = SpeechService.shared

    let dictionary: DictionaryService
    let translation: RoutingTranslationService
    let images: ImageService
    let anki: AnkiService

    private init() {
        let settings = SettingsStore.shared
        dictionary = EnrichedDictionaryService()
        let myMemory = MyMemoryTranslationService(apiKeyProvider: { settings.translationAPIKey })
        let lingva = LingvaTranslationService(endpointProvider: { settings.lingvaEndpoint })
        translation = RoutingTranslationService(
            providers: [
                .opusMT: OpusMTTranslationService(),
                .apple: AppleTranslationService(),
                .myMemory: myMemory,
                .lingva: lingva
            ],
            selection: { settings.translationProvider }
        )
        images = PexelsService(apiKeyProvider: { settings.pexelsAPIKey })
        anki = AnkiService(
            endpointProvider: { settings.ankiEndpoint },
            modelNameProvider: { settings.noteModelName },
            fieldMappingProvider: { settings.ankiFieldMapping }
        )
    }
}
