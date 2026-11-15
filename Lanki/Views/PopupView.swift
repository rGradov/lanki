import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The floating card shown near the cursor. Renders the looked-up word with
/// pronunciation, translation, definition, example and an "Add to Anki" action.
struct PopupView: View {
    @StateObject var viewModel: PopupViewModel
    var onClose: () -> Void
    var onPinChange: (Bool) -> Void

    @State private var isPinned: Bool
    @State private var editing: EditableField?
    @State private var draft = ""

    private enum EditableField: Hashable { case word, translation, definition, synonyms }

    init(
        viewModel: PopupViewModel,
        isPinned: Bool = false,
        onPinChange: @escaping (Bool) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _isPinned = State(initialValue: isPinned)
        self.onPinChange = onPinChange
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Theme.secondaryText.opacity(isPinned ? 0.2 : 0.5))
                .frame(width: 36, height: 5)
                .frame(width: 72, height: 16)
                .overlay(WindowDragHandle(enabled: !isPinned))
                .frame(maxWidth: .infinity)
                .help(isPinned ? "Unpin to move" : "Drag to move")
            header
            switch viewModel.loadState {
            case .loading:
                loadingContent
            case .failed(let message):
                failedContent(message)
            case .loaded:
                loadedContent
            }
        }
        .padding(18)
        .frame(width: 360)
        .popupGlassCard()
        .focusEffectDisabled()
        .task { await viewModel.load() }
        .onExitCommand {
            if editing != nil {
                editing = nil
            } else if !isPinned {
                onClose()
            }
        }
        .onChange(of: editing) { _, new in
            PopupWindowService.shared.setTranslationEditing(new != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lankiEndTranslationEdit)) { _ in
            if editing != nil { editing = nil }
        }
        .onDisappear {
            PopupWindowService.shared.setTranslationEditing(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.gradient)
                    .frame(width: 26, height: 26)
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("Lanki")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            HStack(spacing: 2) {
                Button {
                    isPinned.toggle()
                    onPinChange(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.circle.fill" : "pin.circle")
                        .font(.system(size: 18))
                        .symbolRenderingMode(isPinned ? .monochrome : .hierarchical)
                        .foregroundStyle(isPinned ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin" : "Pin")

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }

    }

    // MARK: - States

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.word)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.word)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Failed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Add it by hand from the menu: Create New Word.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            wordBlock
            translationBlock
            deckTypeRow
            definitionBlock
            if !viewModel.example.isEmpty { exampleBlock }
            synonymsBlock
            if viewModel.imagesEnabled { imageSection }
            addButton
            if case .failed(let message) = viewModel.saveState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Content blocks

    private var wordBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            editableField(.word, title: "Word", value: viewModel.word, font: .systemFont(ofSize: 26, weight: .bold))
            HStack(spacing: 8) {
                if let pron = viewModel.pronunciation, !pron.isEmpty {
                    Text(pron)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                }
                if let pos = viewModel.partOfSpeech, !pos.isEmpty {
                    Text(pos)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassChip(radius: 8)
                        .foregroundStyle(Theme.secondaryText)
                }
                PronunciationButton(
                    url: viewModel.audioURL,
                    word: viewModel.word,
                    language: viewModel.sourceLanguage.code
                )
            }
        }
    }

    private var translationBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            editableField(.translation, title: "Translation", value: viewModel.translation,
                          font: .systemFont(ofSize: 19, weight: .semibold))
            if let refreshError = viewModel.refreshError {
                Text(refreshError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var refreshTranslationButton: some View {
        Button {
            guard finishEditing() else { return }
            Task { await viewModel.refreshTranslation() }
        } label: {
            Group {
                if viewModel.isRefreshingTranslation {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRefreshingTranslation)
        .help("Refresh translation")
        .accessibilityLabel("Refresh translation")
    }

    private var definitionBlock: some View {
        editableField(.definition, title: "Definition", value: viewModel.definition,
                      font: .systemFont(ofSize: 13), multiline: true)
    }

    private func editableField(_ field: EditableField, title: String, value: String,
                               font: NSFont, multiline: Bool = false) -> some View {
        let isEditing = editing == field
        let displayed = isEditing ? draft : value
        let placeholder = "Add \(title.lowercased())"

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if field == .translation {
                    Text(viewModel.targetLanguage.flag)
                        .font(.system(size: 12))
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
                if field == .translation { refreshTranslationButton }
            }
            .frame(height: 22)

            // The label determines the height in both modes. The AppKit editor
            // overlays it with identical font, insets and wrapping, so entering
            // edit mode neither indents the text nor shifts the content below.
            Text(displayed.isEmpty ? placeholder : displayed)
                .font(Font(font))
                .foregroundStyle(displayed.isEmpty ? Theme.secondaryText : Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .opacity(isEditing ? 0 : 1)
                .accessibilityHidden(isEditing)
                .contentShape(Rectangle())
                .onTapGesture { if canEdit(field) { beginEditing(field, value: value) } }
                .help(field == .synonyms ? "Click to edit synonyms, separated by commas" : "Click to edit \(title.lowercased())")
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Edit \(title.lowercased())")
                .accessibilityValue(value)
                .accessibilityAction {
                    if canEdit(field) { beginEditing(field, value: value) }
                }
                .overlay {
                    if isEditing {
                        InlineCardField(text: $draft, font: font, color: NSColor(Theme.primaryText),
                                        multiline: multiline, onCommit: { finishEditing() },
                                        onCancel: { editing = nil })
                            .id(field)
                            .accessibilityLabel(title)
                    }
                }
                .background {
                    if isEditing {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.field)
                            .padding(.horizontal, -6)
                    }
                }
                .overlay {
                    if isEditing {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1)
                            .padding(.horizontal, -6)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func canEdit(_ field: EditableField) -> Bool {
        viewModel.saveState != .saving &&
        !(field == .definition && viewModel.isLoadingDefinition) &&
        !(field == .word && (viewModel.isLoadingDefinition || viewModel.isRefreshingTranslation)) &&
        !(field == .translation && viewModel.isRefreshingTranslation)
    }

    private func beginEditing(_ field: EditableField, value: String) {
        guard editing != field, finishEditing() else { return }
        draft = value
        editing = field
    }

    @discardableResult
    private func finishEditing() -> Bool {
        guard let field = editing else { return true }
        switch field {
        case .word:
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            viewModel.word = draft
            viewModel.commitWordEdit()
        case .translation:
            viewModel.translation = draft
            viewModel.commitTranslationEdit()
        case .definition:
            viewModel.definition = draft
            viewModel.commitDefinitionEdit()
        case .synonyms:
            viewModel.synonyms = draft
            viewModel.commitSynonymsEdit()
        }
        editing = nil
        return true
    }

    private var exampleBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Theme.accent.opacity(0.5))
                .frame(width: 3)
                .clipShape(Capsule())
            Text(viewModel.example)
                .font(.system(size: 13))
                .italic()
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var synonymsBlock: some View {
        editableField(.synonyms, title: "Synonyms", value: viewModel.synonyms,
                      font: .systemFont(ofSize: 13), multiline: true)
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if viewModel.isLoadingImage, viewModel.imageURL == nil {
                    ImageShimmer()
                } else if let url = viewModel.imageURL {
                    MorphingCardImage(url: url)
                } else {
                    dropPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(viewModel.isDropTargeted ? Theme.accent : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.imageURL != nil {
                    Button(role: .destructive) { viewModel.clearImage() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.6), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .help("Remove image")
                    .accessibilityLabel("Remove image")
                    .disabled(viewModel.saveState == .saving)
                }
            }
            .onDrop(of: [.fileURL, .image, .url], isTargeted: $viewModel.isDropTargeted) { providers in
                viewModel.handleDrop(providers: providers)
            }
            .onChange(of: viewModel.isDropTargeted) { _, targeted in
                PopupWindowService.shared.noteDropTargeted(targeted)
            }
            .help("Drop an image to replace")

            if let imageDropError = viewModel.imageDropError {
                Text(imageDropError)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var dropPlaceholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.field)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.secondaryText)
                    Text("Drop an image")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
    }

    // MARK: - Anki controls

    private var deckTypeRow: some View {
        GlassDropdown(
            title: "Deck",
            selection: viewModel.deck,
            options: deckOptions.map { ($0, $0) }
        ) { viewModel.deck = $0 }
    }

    private var deckOptions: [String] {
        var decks = viewModel.decks
        if !decks.contains(viewModel.deck) {
            decks.insert(viewModel.deck, at: 0)
        }
        return decks
    }

    private var addButton: some View {
        Button {
            guard finishEditing() else { return }
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
        }
        .buttonStyle(PrimaryButtonStyle(disabled: addDisabled))
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(addDisabled)
        .help(viewModel.isLoadingDefinition ? "Waiting for the definition…" : "Add to Anki")
    }

    private var addDisabled: Bool {
        viewModel.saveState == .saving || viewModel.isLoadingDefinition ||
        (editing == .word && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// A compact, native-feeling dropdown for the card: a labelled glass control
/// that opens a standard menu. Avoids the boxed NSPopUpButton look that felt
/// out of place in dark mode.
private struct GlassDropdown: View {
    let title: String
    let selection: String
    let options: [(value: String, label: String)]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .tracking(0.4)

            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        onSelect(option.value)
                    } label: {
                        if option.value == selection {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(selection)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .glassChip(radius: 11)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Speaker control that swaps to a native circular ProgressView while the
/// remote pronunciation is buffering, then back to the speaker glyph when
/// playback starts (or after it ends / fails).
struct PronunciationButton: View {
    /// Remote/cached dictionary clip, if any. When missing (or if it fails to
    /// load) the button falls back to system text-to-speech.
    let url: URL?
    let word: String
    let language: String?

    @ObservedObject private var player = AudioPlayer.shared
    @ObservedObject private var speech = SpeechService.shared

    private var isActiveClip: Bool { url != nil && player.activeURL == url }
    private var isSpeaking: Bool { speech.speakingText == word }

    private var showsSpinner: Bool {
        isActiveClip && player.state == .loading
    }

    var body: some View {
        Button(action: playPronunciation) {
            ZStack {
                if showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.bounce, value: isPlaying)
                }
            }
            .frame(width: 18, height: 18)
            .contentTransition(.symbolEffect(.replace))
            .animation(.easeInOut(duration: 0.15), value: showsSpinner)
        }
        .buttonStyle(.plain)
        .disabled(showsSpinner)
        .help(showsSpinner ? "Loading pronunciation…" : "Play pronunciation")
    }

    private var isPlaying: Bool {
        (isActiveClip && player.state == .playing) || isSpeaking
    }

    private func playPronunciation() {
        if let url {
            // Try the real clip; on load failure, speak the word instead.
            player.play(url) {
                SpeechService.shared.speak(word, language: language)
            }
        } else {
            SpeechService.shared.speak(word, language: language)
        }
    }
}

/// Placeholder that pulses while a card image URL or pixels are loading.
private struct ImageShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.field)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0),
                        Color.white.opacity(0.38),
                        Color.white.opacity(0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 180)
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.glassStroke.opacity(0.7), lineWidth: 0.8)
            )
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityLabel("Loading image")
    }
}

/// Keeps the previous photo on screen and eases the new one in over it.
private struct MorphingCardImage: View {
    let url: URL

    @State private var current: NSImage?
    @State private var previous: NSImage?
    @State private var revealed = false

    var body: some View {
        ZStack {
            if let previous {
                photo(previous)
                    .scaleEffect(revealed ? 1.035 : 1)
                    .opacity(revealed ? 0 : 1)
            }
            if let current {
                photo(current)
                    .scaleEffect(revealed ? 1 : 0.97)
                    .opacity(revealed ? 1 : 0)
                    .blur(radius: revealed ? 0 : 6)
            }
            if current == nil && previous == nil {
                ImageShimmer()
            }
        }
        .animation(.easeInOut(duration: 0.32), value: revealed)
        .task(id: url) { await load(url) }
    }

    private func photo(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.glassStroke.opacity(0.7), lineWidth: 0.8)
            )
    }

    private func load(_ url: URL) async {
        let image: NSImage?
        if url.isFileURL {
            image = NSImage(contentsOf: url)
        } else {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            image = NSImage(data: data)
        }
        guard let image, !Task.isCancelled else { return }
        if current == nil {
            current = image
            revealed = true
            return
        }
        previous = current
        current = image
        revealed = false
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.32)) {
                revealed = true
            }
        }
        try? await Task.sleep(nanoseconds: 360_000_000)
        guard !Task.isCancelled else { return }
        previous = nil
    }
}

/// A self-editing AppKit text view. Unlike `TextField`/`NSTextField`, this does
/// not ask the panel for a shared field editor, which crashes on macOS 27.
private struct InlineCardField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var color: NSColor
    var multiline: Bool
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else {
            return scroll
        }
        editor.delegate = context.coordinator
        editor.string = text
        editor.font = font
        editor.textColor = color
        editor.insertionPointColor = color
        editor.typingAttributes = [
            .font: font,
            .foregroundColor: color
        ]
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 0, height: 6)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineBreakMode = .byWordWrapping

        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = multiline
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.font = font
        editor.textColor = color
        editor.insertionPointColor = color
        editor.typingAttributes = [
            .font: font,
            .foregroundColor: color
        ]
        if editor.string != text, editor.window?.firstResponder !== editor {
            editor.string = text
        }
        guard !context.coordinator.didFocus else { return }
        context.coordinator.didFocus = true
        DispatchQueue.main.async {
            guard let window = editor.window else { return }
            if !window.isKeyWindow {
                (window as? PopupPanel)?.allowsKey = true
                window.makeKey()
            }
            window.makeFirstResponder(editor)
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 220,
               height: proposal.height ?? (NSLayoutManager().defaultLineHeight(for: font) + 12))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineCardField
        var didFocus = false

        init(_ parent: InlineCardField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if editor.string != parent.text {
                parent.text = editor.string
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                DispatchQueue.main.async { self.parent.onCancel() }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
                DispatchQueue.main.async { self.parent.onCommit() }
                return true
            }
            return false
        }
    }
}
