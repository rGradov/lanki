import Foundation

/// A language option used for the "translate from / to" dropdowns.
/// `code` is an ISO-639-1 code understood by the translation backends.
struct Language: Identifiable, Hashable, Codable {
    var code: String
    var name: String

    var id: String { code }

    /// Flag emoji derived from a representative region for nicer menus.
    var flag: String { Language.flags[code] ?? "🌐" }

    var displayName: String { "\(flag)  \(name)" }
}

extension Language {
    /// Curated list of commonly used languages. English first as it is the
    /// default study source for the dictionary API.
    static let all: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "ru", name: "Russian"),
        Language(code: "uk", name: "Ukrainian"),
        Language(code: "es", name: "Spanish"),
        Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"),
        Language(code: "it", name: "Italian"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "pl", name: "Polish"),
        Language(code: "nl", name: "Dutch"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "sv", name: "Swedish"),
        Language(code: "cs", name: "Czech"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "zh", name: "Chinese"),
        Language(code: "ar", name: "Arabic"),
        Language(code: "hi", name: "Hindi"),
        Language(code: "he", name: "Hebrew"),
        Language(code: "el", name: "Greek"),
        Language(code: "fi", name: "Finnish"),
        Language(code: "no", name: "Norwegian"),
        Language(code: "da", name: "Danish"),
        Language(code: "ro", name: "Romanian"),
        Language(code: "hu", name: "Hungarian"),
        Language(code: "id", name: "Indonesian"),
        Language(code: "vi", name: "Vietnamese"),
        Language(code: "th", name: "Thai")
    ]

    static func named(_ code: String) -> Language {
        all.first(where: { $0.code == code }) ?? Language(code: code, name: code.uppercased())
    }

    private static let flags: [String: String] = [
        "en": "🇬🇧", "ru": "🇷🇺", "uk": "🇺🇦", "es": "🇪🇸", "fr": "🇫🇷",
        "de": "🇩🇪", "it": "🇮🇹", "pt": "🇵🇹", "pl": "🇵🇱", "nl": "🇳🇱",
        "tr": "🇹🇷", "sv": "🇸🇪", "cs": "🇨🇿", "ja": "🇯🇵", "ko": "🇰🇷",
        "zh": "🇨🇳", "ar": "🇸🇦", "hi": "🇮🇳", "he": "🇮🇱", "el": "🇬🇷",
        "fi": "🇫🇮", "no": "🇳🇴", "da": "🇩🇰", "ro": "🇷🇴", "hu": "🇭🇺",
        "id": "🇮🇩", "vi": "🇻🇳", "th": "🇹🇭"
    ]
}
