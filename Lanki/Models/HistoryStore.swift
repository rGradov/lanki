import Foundation
import Combine

/// Persists recently added words so the History view can group them by day.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    private let defaults = UserDefaults.standard
    private let key = "history.cards"
    private let limit = 500

    @Published private(set) var cards: [WordCard] = []

    private init() {
        load()
    }

    func add(_ card: WordCard) {
        cards.insert(card, at: 0)
        if cards.count > limit { cards = Array(cards.prefix(limit)) }
        save()
    }

    /// Inserts the card, or updates the existing entry with the same id
    /// (used to promote a "translated" entry to "added to Anki").
    func upsert(_ card: WordCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.insert(card, at: 0)
            if cards.count > limit { cards = Array(cards.prefix(limit)) }
        }
        save()
    }

    func remove(_ card: WordCard) {
        cards.removeAll { $0.id == card.id }
        save()
    }

    func clear() {
        cards.removeAll()
        save()
    }

    /// Groups cards into sections keyed by a friendly date label ("Today", etc.).
    func grouped() -> [(title: String, cards: [WordCard])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: cards) { calendar.startOfDay(for: $0.createdAt) }
        return groups.keys.sorted(by: >).map { day in
            (title: Self.label(for: day), cards: groups[day] ?? [])
        }
    }

    private static func label(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: day)
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WordCard].self, from: data) else { return }
        cards = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cards) {
            defaults.set(data, forKey: key)
        }
    }
}
