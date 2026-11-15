import SwiftUI
import AppKit

/// Settings as a System Settings–style split view with a glass sidebar
/// (instead of the old macOS TabView strip).
struct SettingsView: View {
    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $pane)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            SettingsDetail(pane: pane)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 500)
        .background(Theme.settingsCanvas)
    }
}

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, anki, languages, apiKeys, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .anki: return "Anki"
        case .languages: return "Languages"
        case .apiKeys: return "API Keys"
        case .history: return "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .anki: return "rectangle.stack.fill"
        case .languages: return "globe"
        case .apiKeys: return "key.fill"
        case .history: return "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(red: 0.45, green: 0.48, blue: 0.55)
        case .anki: return Color(red: 0.18, green: 0.52, blue: 0.96)
        case .languages: return Color(red: 0.20, green: 0.68, blue: 0.55)
        case .apiKeys: return Color(red: 0.92, green: 0.62, blue: 0.18)
        case .history: return Color(red: 0.62, green: 0.40, blue: 0.92)
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.gradient)
                        .frame(width: 32, height: 32)
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lanki")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Settings")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    SettingsSidebarRow(pane: pane, isSelected: selection == pane) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selection = pane
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Theme.sidebarFill)
        }
    }
}

private struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Theme.secondaryText)
                    .frame(width: 18, height: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected ? Color.white : Theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.accent)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail host

private struct SettingsDetail: View {
    let pane: SettingsPane

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: pane.title)
            detailBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.settingsCanvas)
        .animation(.easeInOut(duration: 0.18), value: pane)
    }

    @ViewBuilder
    private var detailBody: some View {
        switch pane {
        case .general: GeneralSettingsView()
        case .anki: AnkiSettingsView()
        case .languages: LanguageSettingsView()
        case .apiKeys: APISettingsView()
        case .history:
            HistoryView()
                .glassPanel()
                .clipShape(RoundedRectangle(cornerRadius: Theme.glassRadius, style: .continuous))
                .padding(20)
        }
    }
}

/// Pinned "sliver" title that stays at the top of a pane while its content
/// scrolls beneath it (like a pinned SliverPersistentHeader).
private struct PaneHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(Theme.settingsCanvas)
    }
}

// MARK: - Glass form chrome

private struct SettingsGlassForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .glassPanel()
        .clipShape(RoundedRectangle(cornerRadius: Theme.glassRadius, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject private var updater = LankiUpdater.shared
    @State private var accessibilityTrusted = AccessibilityService.shared.isTrusted
    @State private var openAtLogin = LoginItemService.isEnabled
    @State private var openAtLoginNeedsApproval = LoginItemService.requiresApproval
    @State private var openAtLoginError: String?

    var body: some View {
        SettingsGlassForm {
            Section("Shortcut") {
                HStack {
                    Text("Trigger")
                    Spacer()
                    ShortcutRecorder(hotkey: $settings.hotkey) { hk in
                        HotkeyManager.shared.update(with: settings)
                        _ = hk
                    }
                }
                Toggle("Enable global shortcut", isOn: $settings.shortcutEnabled)
                    .onChange(of: settings.shortcutEnabled) { _, _ in
                        HotkeyManager.shared.update(with: settings)
                    }
                Toggle("Clipboard fallback", isOn: $settings.useClipboardFallback)
                Text(settings.useClipboardFallback
                     ? "After the shortcut, Lanki copies the selection with ⌘C (waits until you release ⌘⇧). Old clipboard is restored and never shown as a false selection."
                     : "Only Accessibility selected-text is used. Many apps (VS Code, Telegram, browsers) need clipboard fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Select text in any app, then press \(settings.hotkey.displayString).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in
                        setOpenAtLogin(enabled)
                    }
                Text(openAtLoginNeedsApproval
                     ? "macOS is waiting for approval. Turn Lanki on in System Settings → General → Login Items & Extensions."
                     : "Lanki starts with macOS and stays in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(openAtLoginNeedsApproval ? .orange : .secondary)
                if let openAtLoginError {
                    Text(openAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: settings.appearance) { _, newValue in
                    AppearanceManager.apply(newValue)
                }
                Toggle("Show images on cards", isOn: $settings.enableImages)
            }

            Section("Cache") {
                CacheSettingsSection()
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Text(accessibilityTrusted ? "Accessibility access granted" : "Accessibility access required")
                    Spacer()
                    Button(accessibilityTrusted ? "Open Settings" : "Enable…") {
                        AccessibilityService.shared.openAccessibilitySettings()
                    }
                }
                if !accessibilityTrusted {
                    Text("Turn ON the toggle next to Lanki, then quit and reopen Lanki. Listing the app is not enough — the switch must be green.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Lanki can read the text you select in other apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Toggle("Download updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloadsUpdates },
                    set: { updater.setAutomaticallyDownloadsUpdates($0) }
                ))
                if let version = updater.readyUpdateVersion {
                    Button(LankiUpdater.restartTitle(forVersion: version)) {
                        updater.restartToUpdate()
                    }
                } else {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                Text("Lanki checks once a day. Each update is signed with a key that lives only on your machine, and Lanki refuses any download without a matching signature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.display)
            }
        }
        .onAppear { refreshSystemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSystemStatus()
        }
    }

    private func refreshSystemStatus() {
        accessibilityTrusted = AccessibilityService.shared.isTrusted
        openAtLogin = LoginItemService.isEnabled
        openAtLoginNeedsApproval = LoginItemService.requiresApproval
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            openAtLoginError = nil
        } catch {
            openAtLoginError = error.localizedDescription
        }
        openAtLogin = LoginItemService.isEnabled
        openAtLoginNeedsApproval = LoginItemService.requiresApproval
    }
}

// MARK: - Cache

private struct CacheSettingsSection: View {
    @ObservedObject private var cache = LookupCacheService.shared
    @State private var confirmClear = false

    var body: some View {
        LabeledContent("Stored words", value: "\(cache.entryCount)")
        LabeledContent("Disk usage", value: cache.formattedSize)
        Text("Lookups, images and audio are saved on disk so the same word does not hit the network again after a restart.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Clear Cache…", role: .destructive) {
            confirmClear = true
        }
        .confirmationDialog(
            "Clear lookup cache?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                cache.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes \(cache.entryCount) cached words and \(cache.formattedSize) of images and audio.")
        }
        .onAppear { cache.refreshStats() }
    }
}

// MARK: - Anki

private struct AnkiSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var decks: [String] = []
    @State private var models: [String] = []
    @State private var connection: ConnectionState = .unknown
    @State private var isTesting = false

    enum ConnectionState { case unknown, ok, failed }

    var body: some View {
        SettingsGlassForm {
            Section("Connection") {
                TextField("AnkiConnect endpoint", text: $settings.ankiEndpoint)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if isTesting { ProgressView().controlSize(.small) } else { Text("Test & Load Decks") }
                    }
                    .disabled(isTesting)
                    Spacer()
                    statusLabel
                }
                Text("Requires Anki to be open with the AnkiConnect add-on installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cards") {
                if decks.isEmpty {
                    TextField("Deck name", text: $settings.deckName)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Deck", selection: $settings.deckName) {
                        ForEach(decks, id: \.self) { Text($0).tag($0) }
                    }
                }

                if models.isEmpty {
                    TextField("Note type", text: $settings.noteModelName)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Note type", selection: $settings.noteModelName) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                Text("Must match an existing note type in Anki (e.g. Flat).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Field mapping") {
                Text("Map Lanki values onto your note type’s field names.")
                    .font(.caption).foregroundStyle(.secondary)
                fieldRow("Vocab", text: $settings.ankiFieldMapping.vocab)
                fieldRow("IPA", text: $settings.ankiFieldMapping.ipa)
                fieldRow("Definition (EN)", text: $settings.ankiFieldMapping.definitionEN)
                fieldRow("Example", text: $settings.ankiFieldMapping.example)
                fieldRow("Synonyms", text: $settings.ankiFieldMapping.syn)
                fieldRow("Audio", text: $settings.ankiFieldMapping.audioVocab)
                fieldRow("Image", text: $settings.ankiFieldMapping.image)
                fieldRow("Translation", text: $settings.ankiFieldMapping.translation)
                Button("Reset to Flat defaults") {
                    settings.ankiFieldMapping = .default
                }
            }
        }
        .task { await testConnection() }
    }

    private func fieldRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 120, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch connection {
        case .unknown: EmptyView()
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed:
            Label("Not reachable", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        }
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let anki = ServiceContainer.shared.anki
        if await anki.ping() {
            connection = .ok
            if let names = try? await anki.deckNames() {
                decks = names.sorted()
                if !decks.contains(settings.deckName), let first = decks.first {
                    settings.deckName = first
                }
            }
            if let names = try? await anki.modelNames() {
                models = names.sorted()
                if !models.contains(settings.noteModelName), models.contains("Flat") {
                    settings.noteModelName = "Flat"
                }
            }
        } else {
            connection = .failed
        }
    }
}

// MARK: - Languages

private struct LanguageSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        SettingsGlassForm {
            Section("Translation direction") {
                Picker("Translate from", selection: $settings.sourceLanguage) {
                    ForEach(Language.all) { Text($0.displayName).tag($0.code) }
                }
                Picker("Translate to", selection: $settings.targetLanguage) {
                    ForEach(Language.all) { Text($0.displayName).tag($0.code) }
                }
                HStack {
                    Spacer()
                    Text("\(settings.sourceLang.flag)  \(settings.sourceLang.name)")
                    Image(systemName: "arrow.right")
                    Text("\(settings.targetLang.flag)  \(settings.targetLang.name)")
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Section {
                Text("Definitions come from dictionaryapi.dev, with Datamuse filling IPA/synonyms and Tatoeba filling example sentences when needed. Translation uses the selected provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - API Keys

private struct APISettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        SettingsGlassForm {
            Section("Images – Pexels") {
                SecureField("Pexels API key", text: $settings.pexelsAPIKey)
                    .textFieldStyle(.roundedBorder)
                Link("Get a free Pexels API key", destination: URL(string: "https://www.pexels.com/api/")!)
                    .font(.caption)
            }
            Section("Translation") {
                Picker("Provider", selection: $settings.translationProvider) {
                    ForEach(TranslationProvider.allCases) { Text($0.rawValue).tag($0) }
                }

                switch settings.translationProvider {
                case .opusMT:
                    OpusDownloadSettings()
                    Text("If Opus-MT cannot translate, Lanki tries Apple Translation, then MyMemory and Lingva.")
                        .font(.caption).foregroundStyle(.secondary)
                case .apple:
                    Text("Uses the macOS translation languages. Requires macOS 15 or later. If a language is missing, install it in System Settings → General → Language & Region → Translation Languages.")
                        .font(.caption).foregroundStyle(.secondary)
                case .myMemory:
                    TextField("Email (raises free quota)", text: $settings.translationAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text("MyMemory works without a key. Adding a valid email increases the daily character limit.")
                        .font(.caption).foregroundStyle(.secondary)
                case .lingva:
                    TextField("Lingva instance URL", text: $settings.lingvaEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Text("Lingva Translate is a free Google Translate front-end (no key). Use the public instance or self-host — see github.com/thedaviddelta/lingva-translate for mirrors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct OpusDownloadSettings: View {
    @ObservedObject private var store = OpusMTModelStore.shared

    var body: some View {
        if store.isReady {
            Text("Opus-MT is downloaded. English ↔ Russian runs on this Mac and is not included in the app.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Remove model") { store.remove() }
        } else if case .downloading(let fraction) = store.phase {
            ProgressView(value: fraction) {
                Text("Downloading… \(Int(fraction * 100))%")
            }
            Text("About 230 MB. You can keep using another provider until this finishes.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Download model") { store.download() }
            Text("Optional English ↔ Russian translator, about 230 MB. It is stored in Application Support and is not part of the app.")
                .font(.caption).foregroundStyle(.secondary)
            if case .failed(let message) = store.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    SettingsView()
}
