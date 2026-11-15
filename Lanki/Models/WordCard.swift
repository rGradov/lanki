import Foundation

/// Lifecycle status of a looked-up word.
enum CardStatus: String, Codable {
    case translated       // looked up / translated but not yet saved
    case addedToAnki      // pushed to Anki

    var label: String {
        switch self {
        case .translated: return "Translated"
        case .addedToAnki: return "Added to Anki"
        }
    }
}

/// A fully assembled learning card built from the dictionary, translation and
/// (optionally) image services. This is the model the popup renders and the
/// object that gets pushed to Anki.
struct WordCard: Identifiable, Codable, Equatable {
    var id: UUID = UUID()

    /// The original selected text.
    var word: String

    /// IPA / phonetic spelling, e.g. "/dɪˈsɪʒən/".
    var pronunciation: String?

    /// Primary English definition.
    var definition: String?

    /// Part of speech, e.g. "noun".
    var partOfSpeech: String?

    /// Example sentences pulled from the dictionary.
    var examples: [String] = []

    /// Synonyms (English), e.g. for the Flat note type's Syn field.
    var synonyms: [String] = []

    /// Translation into the user's target language.
    var translation: String?

    /// URL of an illustrative image (Pexels).
    var imageURL: URL?

    /// Remote audio pronunciation, if the dictionary provides one.
    var audioURL: URL?

    /// When the card was created / added.
    var createdAt: Date = Date()

    /// Whether this entry was only translated or also added to Anki.
    var status: CardStatus = .translated

    var firstExample: String? { examples.first }

    /// Comma-separated synonyms for Anki / UI.
    var synonymsText: String? {
        let cleaned = synonyms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }
}
