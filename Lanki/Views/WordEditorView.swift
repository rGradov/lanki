import SwiftUI
import UniformTypeIdentifiers

/// Full window for composing a card by hand and sending it to Anki.
struct WordEditorView: View {
    @StateObject var viewModel: WordEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Word", text: $viewModel.word, placeholder: "the word you’re learning")
                    field("Translation", text: $viewModel.translation, placeholder: "optional — e.g. Озадачен")

                    pronunciationRow
                    field("Part of speech", text: $viewModel.partOfSpeech, placeholder: "noun, verb…")

                    multiline("Definition", text: $viewModel.definition, height: 72)
                    multiline("Example", text: $viewModel.example, height: 56)
                    field("Synonyms", text: $viewModel.synonyms, placeholder: "comma-separated")

                    imageSection
                    deckPicker

                    if let error = viewModel.lookupError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if case .failed(let message) = viewModel.saveState {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            footer
        }
        .background(Theme.settingsCanvas)
        .frame(minWidth: 520, minHeight: 620)
        .task { await viewModel.loadDecks() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.gradient)
                    .frame(width: 28, height: 28)
                Image(systemName: "plus.rectangle.on.folder.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("New Word")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("Fill in what you know — translation is optional.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(Theme.settingsCanvas)
    }

    private var pronunciationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pronunciation")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .tracking(0.3)

            HStack(spacing: 8) {
                TextField("/stʌmpt/", text: $viewModel.pronunciation)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .fieldStyle()

                PronunciationButton(
                    url: viewModel.audioURL,
                    word: viewModel.word,
                    language: viewModel.sourceLanguage.code
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .glassChip(radius: 10)
                .disabled(viewModel.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await viewModel.lookupPronunciation() }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isLookingUpPronunciation {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "text.book.closed")
                        }
                        Text("Look up")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .glassChip(radius: 10)
                .disabled(
                    viewModel.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.isLookingUpPronunciation
                )
            }
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Image")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .tracking(0.3)
                Spacer()
                Button("Choose…") { viewModel.pickImage() }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                if viewModel.imagesEnabled {
                    Button {
                        Task { await viewModel.lookupImage() }
                    } label: {
                        HStack(spacing: 4) {
                            if viewModel.isLookingUpImage {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "photo.badge.magnifyingglass")
                            }
                            Text("Find")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        viewModel.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isLookingUpImage
                    )
                }
                if viewModel.imageURL != nil {
                    Button("Remove", role: .destructive) { viewModel.clearImage() }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.field)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                viewModel.isDropTargeted ? Theme.accent : Theme.fieldBorder,
                                style: StrokeStyle(lineWidth: viewModel.isDropTargeted ? 2 : 1, dash: viewModel.imageURL == nil ? [6, 4] : [])
                            )
                    )

                if viewModel.isLookingUpImage, viewModel.imageURL == nil {
                    ProgressView().controlSize(.small)
                } else if let url = viewModel.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .empty:
                            ProgressView().controlSize(.small)
                        default:
                            placeholderImageLabel
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    placeholderImageLabel
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onDrop(of: [.fileURL, .image], isTargeted: $viewModel.isDropTargeted) { providers in
                viewModel.handleDrop(providers: providers)
            }
        }
    }

    private var placeholderImageLabel: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 22))
                .foregroundStyle(Theme.secondaryText)
            Text("Drop an image here")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var deckPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deck")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .tracking(0.3)
            Picker("Deck", selection: $viewModel.deck) {
                ForEach(viewModel.decks, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                Task { await viewModel.addToAnki() }
            } label: {
                HStack(spacing: 8) {
                    switch viewModel.saveState {
                    case .saving:
                        ProgressView().controlSize(.small).tint(Theme.inkText)
                        Text("Adding…")
                    case .saved:
                        Image(systemName: "checkmark.circle.fill")
                        Text("Added to Anki")
                    default:
                        Image(systemName: "plus.rectangle.on.rectangle")
                        Text("Add to Anki")
                        Text("⌘↩")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.6)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(minWidth: 220)
            }
            .buttonStyle(PrimaryButtonStyle(disabled: !viewModel.canSave))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!viewModel.canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Theme.settingsCanvas)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .tracking(0.3)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .fieldStyle()
        }
    }

    private func multiline(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .tracking(0.3)
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: height)
                .fieldStyle()
        }
    }
}
