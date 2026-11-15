import Foundation

enum AnkiError: LocalizedError {
    case notReachable
    case api(String)
    case badResponse
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .notReachable: return "Can't reach Anki. Is Anki running with the AnkiConnect add-on?"
        case .api(let message): return message
        case .badResponse: return "Unexpected response from AnkiConnect."
        case .duplicate(let word): return "“\(word)” is already in this deck."
        }
    }
}

/// Talks to the AnkiConnect add-on (default http://localhost:8765) using its
/// JSON-RPC-style protocol (version 6).
final class AnkiService {
    private let session: URLSession
    private let endpointProvider: () -> String
    private let modelNameProvider: () -> String
    private let fieldMappingProvider: () -> AnkiFieldMapping

    init(
        session: URLSession = .shared,
        endpointProvider: @escaping () -> String,
        modelNameProvider: @escaping () -> String = { "Flat" },
        fieldMappingProvider: @escaping () -> AnkiFieldMapping = { .default }
    ) {
        self.session = session
        self.endpointProvider = endpointProvider
        self.modelNameProvider = modelNameProvider
        self.fieldMappingProvider = fieldMappingProvider
    }

    // MARK: - Public API

    func ping() async -> Bool {
        (try? await invoke(action: "version", params: [:]) as Int) != nil
    }

    func deckNames() async throws -> [String] {
        try await invoke(action: "deckNames", params: [:])
    }

    func modelNames() async throws -> [String] {
        try await invoke(action: "modelNames", params: [:])
    }

    /// Creates a note from `card` using the configured note type + field mapping.
    /// Throws `AnkiError.duplicate` when the word already exists in the target deck.
    @discardableResult
    func addCard(_ card: WordCard, deck: String) async throws -> Int64 {
        let note = makeNote(from: card, deck: deck)
        do {
            let id: Int64 = try await invoke(action: "addNote", params: ["note": note])
            return id
        } catch AnkiError.api(let message) where isDuplicateError(message) {
            throw AnkiError.duplicate(card.word)
        }
    }

    // MARK: - Note construction

    private func makeNote(from card: WordCard, deck: String) -> [String: Any] {
        let mapping = fieldMappingProvider()
        let modelName = modelNameProvider()
        let safeWord = sanitizedFilename(card.word)

        // Plain field values — the Anki card template owns the HTML chrome.
        var fields: [String: String] = [:]
        setField(&fields, mapping.vocab, card.word)
        setField(&fields, mapping.ipa, cleanedIPA(card.pronunciation))
        setField(&fields, mapping.definitionEN, card.definition)
        setField(&fields, mapping.example, card.firstExample)
        setField(&fields, mapping.translation, card.translation)
        setField(&fields, mapping.syn, card.synonymsText)
        // Media fields start empty; AnkiConnect appends [sound:…] / <img> into them.
        setField(&fields, mapping.audioVocab, "")
        setField(&fields, mapping.image, "")

        var note: [String: Any] = [
            "deckName": deck,
            "modelName": modelName,
            "fields": fields,
            "tags": ["lanki"],
            "options": [
                "allowDuplicate": false,
                "duplicateScope": "deck",
                "duplicateScopeOptions": [
                    "deckName": deck,
                    "checkChildren": false,
                    "checkAllModels": false
                ]
            ]
        ]

        if let imageURL = card.imageURL {
            let filename = "\(safeWord).jpg"
            var picture: [String: Any] = [
                "filename": filename,
                "fields": [mapping.image]
            ]
            if imageURL.isFileURL, let data = try? Data(contentsOf: imageURL) {
                picture["data"] = data.base64EncodedString()
            } else {
                picture["url"] = imageURL.absoluteString
            }
            note["picture"] = [picture]
        }

        if let audioURL = card.audioURL {
            let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
            let filename = "\(safeWord).\(ext)"
            var audio: [String: Any] = [
                "filename": filename,
                "fields": [mapping.audioVocab]
            ]
            if audioURL.isFileURL, let data = try? Data(contentsOf: audioURL) {
                audio["data"] = data.base64EncodedString()
            } else {
                audio["url"] = audioURL.absoluteString
            }
            note["audio"] = [audio]
        }

        return note
    }

    private func setField(_ fields: inout [String: String], _ name: String, _ value: String?) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        fields[key] = value ?? ""
    }

    /// Strips surrounding `/…/` so the Anki template can wrap IPA itself
    /// without producing `/ /əˈbɔːd/ /`.
    private func cleanedIPA(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("/"), value.hasSuffix("/"), value.count > 2 {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private func sanitizedFilename(_ word: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(cleaned)
        return result.isEmpty ? "lanki_audio" : result
    }

    private func isDuplicateError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("duplicate") || lower.contains("already exists")
    }

    // MARK: - Transport

    private func invoke<T>(action: String, params: [String: Any]) async throws -> T {
        guard let url = URL(string: endpointProvider()) else { throw AnkiError.notReachable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["action": action, "version": 6, "params": params]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw AnkiError.notReachable
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnkiError.badResponse
        }
        if let error = json["error"] as? String {
            throw AnkiError.api(error)
        }
        guard let result = json["result"] as? T else {
            throw AnkiError.badResponse
        }
        return result
    }
}
