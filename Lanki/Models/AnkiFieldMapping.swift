import Foundation

/// Maps Lanki card data onto the user's Anki note-type fields.
/// Defaults match the "Flat" note type (Vocab, IPA, Definition_EN, …).
struct AnkiFieldMapping: Codable, Equatable {
    var vocab: String
    var ipa: String
    var definitionEN: String
    var example: String
    var syn: String
    var audioVocab: String
    var image: String
    var translation: String

    static let `default` = AnkiFieldMapping(
        vocab: "Vocab",
        ipa: "IPA",
        definitionEN: "Definition_EN",
        example: "Example",
        syn: "Syn",
        audioVocab: "Audio_Vocab",
        image: "Image",
        translation: "Translation"
    )
}
