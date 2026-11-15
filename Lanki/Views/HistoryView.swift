import SwiftUI

/// Shows recently added words grouped by day (Today, Yesterday, …).
struct HistoryView: View {
    @ObservedObject var history = HistoryStore.shared

    var body: some View {
        VStack(spacing: 0) {
            if history.cards.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No translations yet")
                .font(.headline)
            Text("Every word you look up will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(history.grouped(), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.cards) { card in
                        row(card)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(history.cards.count) translations")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear All", role: .destructive) { history.clear() }
                    .controlSize(.small)
            }
            .padding(10)
            .background(.ultraThinMaterial)
        }
    }

    private func row(_ card: WordCard) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(card.word)
                        .font(.system(size: 14, weight: .semibold))
                    Text(Self.timeFormatter.string(from: card.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let translation = card.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            statusBadge(card.status)
        }
        .padding(.vertical, 3)
        .swipeActions {
            Button("Delete", role: .destructive) { history.remove(card) }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: CardStatus) -> some View {
        let added = status == .addedToAnki
        HStack(spacing: 4) {
            Image(systemName: added ? "checkmark.circle.fill" : "character.book.closed")
                .font(.system(size: 10, weight: .semibold))
            Text(status.label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(added ? Color.green : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((added ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

#Preview {
    HistoryView().frame(width: 480, height: 400)
}
