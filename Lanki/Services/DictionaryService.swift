import Foundation

/// Normalized dictionary lookup result.
struct WordDefinition {
    let word: String
    let pronunciation: String?
    let partOfSpeech: String?
    let definition: String
    let examples: [String]
    let synonyms: [String]
    let audioURL: URL?
}

enum DictionaryError: LocalizedError {
    case notFound
    case network(Error)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notFound: return "No definition found."
        case .network(let error): return error.localizedDescription
        case .decoding: return "Could not read the dictionary response."
        }
    }
}

/// Abstraction so the definition source can be swapped without touching the VM.
protocol DictionaryService {
    func lookup(_ word: String) async throws -> WordDefinition
}

/// Free dictionary backed by https://api.dictionaryapi.dev (English).
final class FreeDictionaryService: DictionaryService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func lookup(_ word: String) async throws -> WordDefinition {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = query.split(separator: " ").first.map(String.init) ?? query
        guard let encoded = firstWord.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            throw DictionaryError.notFound
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw DictionaryError.network(error)
        }

        guard let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data),
              let entry = entries.first else {
            throw DictionaryError.notFound
        }

        // Prefer an IPA string that actually has text (audio-only entries are common).
        let phonetic = entry.phonetic
            ?? entry.phonetics?.first(where: { ($0.text?.isEmpty == false) })?.text

        let audio = entry.phonetics?
            .compactMap { $0.audio }
            .first(where: { !$0.isEmpty })
        let audioURL = audio.flatMap { URL(string: $0.hasPrefix("//") ? "https:\($0)" : $0) }

        let meanings = entry.meanings ?? []
        let definition = meanings
            .flatMap { $0.definitions ?? [] }
            .compactMap { $0.definition }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .flatMap { DictionaryCopy.cleanedDefinition($0) } ?? ""

        let examples = meanings
            .flatMap { $0.definitions ?? [] }
            .compactMap { $0.example }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Synonyms live both on meanings and on individual definitions.
        var synonyms: [String] = []
        for meaning in meanings {
            synonyms.append(contentsOf: meaning.synonyms ?? [])
            for item in meaning.definitions ?? [] {
                synonyms.append(contentsOf: item.synonyms ?? [])
            }
        }
        synonyms = Self.uniquePreservingOrder(synonyms)

        let partOfSpeech = meanings.first(where: { !($0.partOfSpeech?.isEmpty ?? true) })?.partOfSpeech

        guard !definition.isEmpty || phonetic != nil || audioURL != nil || !examples.isEmpty || !synonyms.isEmpty else {
            throw DictionaryError.notFound
        }

        return WordDefinition(
            word: entry.word ?? query,
            pronunciation: phonetic,
            partOfSpeech: partOfSpeech,
            definition: definition,
            examples: Array(examples.prefix(3)),
            synonyms: Array(synonyms.prefix(8)),
            audioURL: audioURL
        )
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }
}

// MARK: - dictionaryapi.dev DTOs

private struct DictionaryEntry: Decodable {
    let word: String?
    let phonetic: String?
    let phonetics: [Phonetic]?
    let meanings: [Meaning]?
}

private struct Phonetic: Decodable {
    let text: String?
    let audio: String?
}

private struct Meaning: Decodable {
    let partOfSpeech: String?
    let definitions: [Definition]?
    let synonyms: [String]?
}

private struct Definition: Decodable {
    let definition: String?
    let example: String?
    let synonyms: [String]?
}

// MARK: - Datamuse enrichment (IPA + synonyms)

/// Free lexical API — no key required. Used to fill gaps left by Free Dictionary.
/// Docs: https://www.datamuse.com/api/
final class DatamuseEnrichmentService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func synonyms(for word: String, limit: Int = 8) async -> [String] {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty,
              var components = URLComponents(string: "https://api.datamuse.com/words") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "rel_syn", value: query),
            URLQueryItem(name: "max", value: String(limit))
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let data = try? await session.data(for: request).0,
              let rows = try? JSONDecoder().decode([DatamuseWord].self, from: data) else {
            return []
        }
        return rows.map(\.word).filter { !$0.isEmpty }
    }

    /// Returns IPA like "/hˈæpi/" when Datamuse knows the pronunciation.
    func ipa(for word: String) async -> String? {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty,
              var components = URLComponents(string: "https://api.datamuse.com/words") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "sp", value: query),
            URLQueryItem(name: "md", value: "r"),
            URLQueryItem(name: "ipa", value: "1"),
            URLQueryItem(name: "max", value: "1")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let data = try? await session.data(for: request).0,
              let rows = try? JSONDecoder().decode([DatamuseWord].self, from: data),
              let tags = rows.first?.tags else {
            return nil
        }
        guard let raw = tags.first(where: { $0.hasPrefix("ipa_pron:") })?
            .dropFirst("ipa_pron:".count),
              !raw.isEmpty else {
            return nil
        }
        let trimmed = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return trimmed }
        return "/\(trimmed)/"
    }
}

private struct DatamuseWord: Decodable {
    let word: String
    let tags: [String]?
}

enum DictionaryCopy {
    static func cleanedDefinition(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lower = trimmed.lowercased()
        if lower.contains("no definition") { return "" }
        return trimmed
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .dotMatchesLineSeparators) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tatoeba examples

/// Free example sentences from Tatoeba (no key).
/// Docs: https://en.wiki.tatoeba.org/articles/show/api
final class TatoebaExampleService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func examples(for word: String, limit: Int = 3) async -> [String] {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              var components = URLComponents(string: "https://tatoeba.org/en/api_v0/search") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "from", value: "eng"),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "orphans", value: "no"),
            URLQueryItem(name: "unapproved", value: "no"),
            URLQueryItem(name: "sort", value: "relevance")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        guard let data = try? await session.data(for: request).0,
              let response = try? JSONDecoder().decode(TatoebaSearchResponse.self, from: data) else {
            return []
        }

        let needle = query.lowercased()
        let sentences = response.results
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            // Prefer sentences that actually contain the looked-up word.
            .sorted { lhs, rhs in
                let l = lhs.lowercased().contains(needle)
                let r = rhs.lowercased().contains(needle)
                if l == r { return lhs.count < rhs.count }
                return l && !r
            }

        var seen = Set<String>()
        var unique: [String] = []
        for sentence in sentences {
            let key = sentence.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(sentence)
            if unique.count >= limit { break }
        }
        return unique
    }
}

private struct TatoebaSearchResponse: Decodable {
    let results: [TatoebaSentence]
}

private struct TatoebaSentence: Decodable {
    let text: String
}

// MARK: - Composite enrichment

/// Wiktionary REST definitions. Used because dictionaryapi.dev often hangs.
final class WiktionaryDictionaryService: DictionaryService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func lookup(_ word: String) async throws -> WordDefinition {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = query.split(separator: " ").first.map(String.init) ?? query
        guard let encoded = firstWord.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(encoded)") else {
            throw DictionaryError.notFound
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lanki/1.1 (macOS dictionary lookup)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DictionaryError.network(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DictionaryError.notFound
        }

        guard let payload = try? JSONDecoder().decode([String: [WiktionaryMeaning]].self, from: data) else {
            throw DictionaryError.decoding
        }
        let meanings = payload["en"] ?? payload.first(where: { $0.key.hasPrefix("en") })?.value ?? []
        guard let first = meanings.first else { throw DictionaryError.notFound }

        let definitionHTML = first.definitions?
            .compactMap { $0.definition }
            .map(DictionaryCopy.stripHTML)
            .first { !$0.isEmpty } ?? ""
        let definition = DictionaryCopy.cleanedDefinition(definitionHTML)

        let examples = meanings
            .flatMap { $0.definitions ?? [] }
            .flatMap { $0.examples ?? [] }
            .map(DictionaryCopy.stripHTML)
            .filter { !$0.isEmpty }

        guard !definition.isEmpty || !examples.isEmpty else { throw DictionaryError.notFound }

        return WordDefinition(
            word: firstWord,
            pronunciation: nil,
            partOfSpeech: first.partOfSpeech,
            definition: definition,
            examples: Array(examples.prefix(3)),
            synonyms: [],
            audioURL: nil
        )
    }
}

private struct WiktionaryMeaning: Decodable {
    let partOfSpeech: String?
    let language: String?
    let definitions: [WiktionaryDefinition]?
}

private struct WiktionaryDefinition: Decodable {
    let definition: String?
    let examples: [String]?
}

/// Wiktionary first (dictionaryapi.dev often hangs), then Free Dictionary.
/// Datamuse fills missing IPA / synonyms. Tatoeba is skipped — it is too slow
/// to block the card.
final class EnrichedDictionaryService: DictionaryService {
    private let primary: FreeDictionaryService
    private let wiktionary: WiktionaryDictionaryService
    private let datamuse: DatamuseEnrichmentService

    init(
        primary: FreeDictionaryService = FreeDictionaryService(),
        wiktionary: WiktionaryDictionaryService = WiktionaryDictionaryService(),
        datamuse: DatamuseEnrichmentService = DatamuseEnrichmentService()
    ) {
        self.primary = primary
        self.wiktionary = wiktionary
        self.datamuse = datamuse
    }

    func lookup(_ word: String) async throws -> WordDefinition {
        let query = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = try await firstDefinition(for: query)

        let needsIPA = (base.pronunciation?.isEmpty ?? true)
        let needsSynonyms = base.synonyms.isEmpty

        async let ipaFill: String? = needsIPA ? datamuse.ipa(for: query) : nil
        async let synFill: [String] = needsSynonyms ? datamuse.synonyms(for: query) : []

        let ipa = await ipaFill
        let synonyms = await synFill

        let definition = DictionaryCopy.cleanedDefinition(base.definition)
        return WordDefinition(
            word: base.word,
            pronunciation: needsIPA ? ipa : base.pronunciation,
            partOfSpeech: base.partOfSpeech,
            definition: definition,
            examples: base.examples,
            synonyms: needsSynonyms ? synonyms : base.synonyms,
            audioURL: base.audioURL
        )
    }

    private func firstDefinition(for query: String) async throws -> WordDefinition {
        do {
            let wiki = try await wiktionary.lookup(query)
            if !DictionaryCopy.cleanedDefinition(wiki.definition).isEmpty || !wiki.examples.isEmpty {
                return wiki
            }
        } catch {
            // Fall through to Free Dictionary.
        }

        return try await primary.lookup(query)
    }
}
