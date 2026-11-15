import Foundation

enum TranslationError: LocalizedError {
    case badRequest
    case network(Error)
    case empty
    case api(String)

    var errorDescription: String? {
        switch self {
        case .badRequest: return "Invalid translation request."
        case .network(let error): return error.localizedDescription
        case .empty: return "No translation returned."
        case .api(let message): return message
        }
    }
}

/// The translation back-ends the user can pick between in Settings.
enum TranslationProvider: String, CaseIterable, Identifiable, Codable {
    case opusMT = "Opus-MT"
    case apple = "Apple Translation"
    case myMemory = "MyMemory"
    case lingva = "Lingva Translate"

    var id: String { rawValue }

    /// Compact label for menus.
    var shortLabel: String {
        switch self {
        case .opusMT: return "Opus-MT"
        case .apple: return "Apple"
        case .myMemory: return "MyMemory"
        case .lingva: return "Lingva"
        }
    }

    /// On-device providers. Opus-MT falls through to Apple, then to the network APIs.
    var isLocal: Bool {
        switch self {
        case .opusMT, .apple: return true
        case .myMemory, .lingva: return false
        }
    }
}

/// A translation back-end. All providers take the same input (text + language
/// codes) and return the same output (a plain translated string); each has its
/// own transport and response mapper.
protocol TranslationService {
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

/// Sentence-case display form for a translation: first letter capital, rest
/// lower, no trailing punctuation. Also used to reject "THAT" / "That." when
/// the target language is not English.
enum TranslationStyle {
    static func normalize(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = CharacterSet(charactersIn: ".!?…;:,")
        while let last = trimmed.unicodeScalars.last, trailing.contains(last) {
            trimmed = String(trimmed.unicodeScalars.dropLast())
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty else { return "" }
        let lowered = trimmed.lowercased()
        guard let first = lowered.first else { return lowered }
        return String(first).uppercased() + lowered.dropFirst()
    }

    /// True when `text` looks like a real translation into `language`, not an
    /// echo of the source, a transliteration ("Стампд"), or encoding garbage.
    static func isPlausibleTranslation(_ text: String, language: String, sourceText: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        guard matchesTarget(candidate, language: language, sourceText: sourceText) else { return false }
        if looksLikeEncodingGarbage(candidate) { return false }
        if looksLikeTransliteration(candidate, of: sourceText) { return false }
        return true
    }

    /// True when `text` looks like it belongs to `language` and is not just
    /// the source word echoed back.
    static func matchesTarget(_ text: String, language: String, sourceText: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        if candidate.localizedLowercase == source.localizedLowercase { return false }

        switch language.lowercased() {
        case "ru", "uk", "be", "bg", "sr", "mk":
            return candidate.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        case "ar", "fa", "ur":
            return candidate.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        case "he":
            return candidate.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
        case "zh":
            return candidate.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        case "ja":
            return candidate.unicodeScalars.contains {
                (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
            }
        case "ko":
            return candidate.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }
        case "el":
            return candidate.unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) }
        case "th":
            return candidate.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
        default:
            return candidate.contains { $0.isLetter }
        }
    }

    private static func looksLikeEncodingGarbage(_ text: String) -> Bool {
        if text.contains("&") && text.contains(";") { return true }
        let letters = text.filter { $0.isLetter }
        guard !letters.isEmpty else { return true }
        let latinOnly = text.unicodeScalars.allSatisfy { $0.value < 128 }
        let allCaps = letters.allSatisfy { $0.isUppercase }
        return latinOnly && allCaps && letters.count >= 8
    }

    /// "Stumped" → "Стампд" is the same word spelled in another alphabet.
    private static func looksLikeTransliteration(_ translation: String, of source: String) -> Bool {
        let a = foldPhonetic(source)
        let b = foldPhonetic(translation)
        guard !a.isEmpty, !b.isEmpty else { return false }
        let dist = levenshtein(Array(a), Array(b))
        let denom = max(a.count, b.count)
        guard denom > 0 else { return false }
        if min(a.count, b.count) <= 4 {
            return dist <= 1 && abs(a.count - b.count) <= 1
        }
        return Double(dist) / Double(denom) <= 0.45 && abs(a.count - b.count) <= 3
    }

    private static func foldPhonetic(_ text: String) -> String {
        var out = ""
        for ch in text.lowercased() {
            if let mapped = cyrillicToLatin[ch] {
                out += mapped
            } else if ch.isLetter, ch.isASCII {
                out.append(ch)
            }
        }
        return out
    }

    private static let cyrillicToLatin: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
        "ж": "zh", "з": "z", "и": "i", "й": "i", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g"
    ]

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for (i, ca) in a.enumerated() {
            cur[0] = i + 1
            for (j, cb) in b.enumerated() {
                let cost = ca == cb ? 0 : 1
                cur[j + 1] = min(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Delegates to whichever concrete provider is currently selected in Settings.
/// Keeps call sites (the popup view model) agnostic of the chosen back-end.
final class RoutingTranslationService: TranslationService {
    private let providers: [TranslationProvider: TranslationService]
    private let selection: () -> TranslationProvider

    init(providers: [TranslationProvider: TranslationService], selection: @escaping () -> TranslationProvider) {
        self.providers = providers
        self.selection = selection
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, using: selection())
    }

    func translate(
        _ text: String,
        from source: String,
        to target: String,
        using provider: TranslationProvider
    ) async throws -> String {
        try await translateFirst(text, from: source, to: target, order: Self.fallbackOrder(startingAt: provider))
    }

    /// Skips on-device models and asks MyMemory, then Lingva.
    /// Prefers a result that differs from `current` so a refresh can show another wording.
    func translateFromNetwork(
        _ text: String,
        from source: String,
        to target: String,
        preferringDifferentFrom current: String
    ) async throws -> String {
        let order: [TranslationProvider] = [.myMemory, .lingva]
        var sameAsCurrent: String?
        var lastError: Error = TranslationError.empty
        for chosen in order {
            do {
                let result = try await translateOnce(text, from: source, to: target, using: chosen)
                if result.localizedCaseInsensitiveCompare(current) != .orderedSame {
                    return result
                }
                sameAsCurrent = result
            } catch {
                lastError = error
            }
        }
        if let sameAsCurrent { return sameAsCurrent }
        throw lastError
    }

    /// Opus-MT → Apple Translation → MyMemory → Lingva.
    /// A provider chosen in Settings starts the chain at that step.
    private static func fallbackOrder(startingAt provider: TranslationProvider) -> [TranslationProvider] {
        switch provider {
        case .opusMT:
            return [.opusMT, .apple, .myMemory, .lingva]
        case .apple:
            return [.apple, .myMemory, .lingva]
        case .myMemory:
            return [.myMemory, .lingva]
        case .lingva:
            return [.lingva, .myMemory]
        }
    }

    private func translateFirst(
        _ text: String,
        from source: String,
        to target: String,
        order: [TranslationProvider]
    ) async throws -> String {
        var lastError: Error = TranslationError.empty
        for chosen in order {
            do {
                return try await translateOnce(text, from: source, to: target, using: chosen)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func translateOnce(
        _ text: String,
        from source: String,
        to target: String,
        using provider: TranslationProvider
    ) async throws -> String {
        guard let service = providers[provider] else { throw TranslationError.empty }
        let raw = try await service.translate(text, from: source, to: target)
        let normalized = TranslationStyle.normalize(raw)
        guard TranslationStyle.isPlausibleTranslation(normalized, language: target, sourceText: text) else {
            throw TranslationError.empty
        }
        return normalized
    }
}

/// Uses the free MyMemory translation API (no key required). An optional API
/// key (a valid email) raises the daily character quota.
final class MyMemoryTranslationService: TranslationService {
    private let session: URLSession
    private let apiKeyProvider: () -> String

    init(session: URLSession = .shared, apiKeyProvider: @escaping () -> String = { "" }) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.empty }

        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        var items = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "langpair", value: "\(source)|\(target)")
        ]
        let key = apiKeyProvider().trimmingCharacters(in: .whitespaces)
        if key.contains("@") { items.append(URLQueryItem(name: "de", value: key)) }
        components?.queryItems = items

        guard let url = components?.url else { throw TranslationError.badRequest }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw TranslationError.network(error)
        }

        guard let response = try? JSONDecoder().decode(MyMemoryResponse.self, from: data) else {
            throw TranslationError.empty
        }

        var candidates: [String] = []
        if let translated = response.responseData?.translatedText { candidates.append(translated) }
        for match in response.matches ?? [] {
            if let text = match.translation { candidates.append(text) }
        }

        for raw in candidates {
            let decoded = raw.decodedHTMLEntities()
            let normalized = TranslationStyle.normalize(decoded)
            if TranslationStyle.isPlausibleTranslation(normalized, language: target, sourceText: trimmed) {
                return decoded
            }
        }
        throw TranslationError.empty
    }
}

private struct MyMemoryResponse: Decodable {
    let responseData: ResponseData?
    let matches: [Match]?
    struct ResponseData: Decodable { let translatedText: String? }
    struct Match: Decodable { let translation: String? }
}

/// Uses a Lingva Translate instance (Google Translate front-end, no key).
/// Public API: `GET {base}/api/v1/{source}/{target}/{text}` → `{ "translation": "…" }`.
/// See https://github.com/thedaviddelta/lingva-translate.
///
/// `lingva.ml` is often Cloudflare-rate-limited (HTTP 429 / error 1015), so this
/// service automatically retries a few public mirrors when the configured
/// endpoint fails.
final class LingvaTranslationService: TranslationService {
    private let session: URLSession
    private let endpointProvider: () -> String

    /// Known public instances from the upstream README. Tried after the
    /// user-configured endpoint when that one is down / rate-limited.
    private static let fallbackEndpoints = [
        "https://lingva.ml",
        "https://translate.igna.wtf",
        "https://lingva.lunar.icu",
        "https://translate.plausibility.cloud"
    ]

    /// encodeURIComponent-compatible set (ASCII only).
    private static let pathAllowed: CharacterSet = {
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    }()

    init(session: URLSession = .shared, endpointProvider: @escaping () -> String = { "https://lingva.ml" }) {
        self.session = session
        self.endpointProvider = endpointProvider
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslationError.empty }

        let src = Self.mapLanguageCode(source.isEmpty ? "auto" : source)
        let dst = Self.mapLanguageCode(target)
        let encodedText = trimmed.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? trimmed

        let bases = candidateBases()
        let outcome = await withTaskGroup(of: Result<String, Error>.self) { group -> Result<String, Error> in
            for base in bases {
                group.addTask {
                    do {
                        let text = try await self.translateOnce(
                            base: base,
                            source: src,
                            target: dst,
                            encodedText: encodedText
                        )
                        return .success(text)
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var lastError: Error = TranslationError.empty
            var winner: String?
            for await result in group {
                switch result {
                case .success(let text) where winner == nil:
                    winner = text
                    group.cancelAll()
                case .failure(let error) where winner == nil:
                    lastError = error
                default:
                    break
                }
            }
            if let winner { return .success(winner) }
            return .failure(lastError)
        }

        switch outcome {
        case .success(let text): return text
        case .failure(let error): throw error
        }
    }

    // MARK: - Private

    private func candidateBases() -> [String] {
        var bases: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            while value.hasSuffix("/") { value.removeLast() }
            let key = value.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            bases.append(value)
        }

        append(endpointProvider())
        Self.fallbackEndpoints.forEach(append)
        return bases
    }

    private func translateOnce(
        base: String,
        source: String,
        target: String,
        encodedText: String
    ) async throws -> String {
        guard let url = URL(string: "\(base)/api/v1/\(source)/\(target)/\(encodedText)") else {
            throw TranslationError.badRequest
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 4

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranslationError.network(error)
        }

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            // Cloudflare rate limit / instance outage — try next mirror.
            if let payload = try? JSONDecoder().decode(LingvaResponse.self, from: data),
               let message = payload.error, !message.isEmpty {
                throw TranslationError.api("Lingva (\(base)): \(message)")
            }
            throw TranslationError.api("Lingva (\(base)) HTTP \(http.statusCode)")
        }

        guard let payload = try? JSONDecoder().decode(LingvaResponse.self, from: data) else {
            throw TranslationError.empty
        }
        if let message = payload.error, !message.isEmpty {
            throw TranslationError.api("Lingva: \(message)")
        }
        guard let translated = payload.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translated.isEmpty else {
            throw TranslationError.empty
        }
        return translated
    }

    /// Lingva follows Google Translate codes; a few ISO-639-1 codes differ.
    private static func mapLanguageCode(_ code: String) -> String {
        switch code.lowercased() {
        case "he": return "iw"   // Hebrew
        case "zh-cn", "zh_cn": return "zh"
        case "nb", "nn": return "no"
        default: return code.lowercased()
        }
    }
}

private struct LingvaResponse: Decodable {
    let translation: String?
    let error: String?
}

private extension String {
    /// MyMemory occasionally returns HTML-escaped characters.
    func decodedHTMLEntities() -> String {
        replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
