import Foundation
import CryptoKit
import Combine

/// On-disk record for a successful lookup. Media fields point at local files
/// inside the cache directory whenever download succeeded.
struct CachedLookup: Codable, Equatable {
    var word: String
    var sourceLanguage: String
    var targetLanguage: String
    /// Translation provider this entry was produced with (e.g. "MyMemory").
    /// The same word translated via a different provider is a separate entry.
    var provider: String = ""
    var pronunciation: String?
    var partOfSpeech: String?
    var definition: String?
    var example: String?
    var synonyms: String?
    var translation: String?
    /// Relative path under the cache root, e.g. "media/images/abc.jpg"
    var imageRelativePath: String?
    /// Explicit removal suppresses automatic image lookup on future opens.
    /// Optional for compatibility with records written before removal existed.
    var imageRemoved: Bool?
    var audioRelativePath: String?
    /// Original remote URLs (kept so we can re-download if a file went missing).
    var remoteImageURL: URL?
    var remoteAudioURL: URL?
    var cachedAt: Date

    func imageURL(cacheRoot: URL) -> URL? {
        guard let imageRelativePath else { return nil }
        return cacheRoot.appendingPathComponent(imageRelativePath)
    }

    func audioURL(cacheRoot: URL) -> URL? {
        guard let audioRelativePath else { return nil }
        return cacheRoot.appendingPathComponent(audioRelativePath)
    }
}

/// Persistent lookup + media cache. Survives app relaunches and reboots.
/// Stored under Application Support so it is not casually purged like system Caches.
@MainActor
final class LookupCacheService: ObservableObject {
    static let shared = LookupCacheService()

    @Published private(set) var byteSize: Int64 = 0
    @Published private(set) var entryCount: Int = 0

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private(set) lazy var rootURL: URL = {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base
            .appendingPathComponent("Lanki", isDirectory: true)
            .appendingPathComponent("LookupCache", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("lookups"), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("media/images"), withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: root.appendingPathComponent("media/audio"), withIntermediateDirectories: true)
        return root
    }()

    private var lookupsURL: URL { rootURL.appendingPathComponent("lookups", isDirectory: true) }
    private var imagesURL: URL { rootURL.appendingPathComponent("media/images", isDirectory: true) }
    private var audioURL: URL { rootURL.appendingPathComponent("media/audio", isDirectory: true) }

    private init() {
        refreshStats()
    }

    // MARK: - Lookup API

    func cachedLookup(word: String, source: String, target: String, provider: String) -> CachedLookup? {
        let file = lookupsURL.appendingPathComponent(lookupFileName(word: word, source: source, target: target, provider: provider))
        guard let data = try? Data(contentsOf: file),
              var entry = try? decoder.decode(CachedLookup.self, from: data) else {
            return nil
        }

        // If a media file vanished, clear the relative path so the caller can refetch.
        if let rel = entry.imageRelativePath {
            let path = rootURL.appendingPathComponent(rel).path
            if !fileManager.fileExists(atPath: path) { entry.imageRelativePath = nil }
        }
        if let rel = entry.audioRelativePath {
            let path = rootURL.appendingPathComponent(rel).path
            if !fileManager.fileExists(atPath: path) { entry.audioRelativePath = nil }
        }
        return entry
    }

    /// Saves lookup metadata and downloads remote image/audio into the cache.
    /// A nil media URL keeps the previous file. A local file URL is copied in
    /// and, when it lives outside the cache, replaces the stored remote URL.
    func store(
        word: String,
        source: String,
        target: String,
        provider: String,
        pronunciation: String?,
        partOfSpeech: String?,
        definition: String?,
        example: String?,
        synonyms: String?,
        translation: String?,
        remoteImageURL: URL?,
        remoteAudioURL: URL?,
        imageRemoved: Bool = false
    ) async {
        let normalized = normalizedWord(word)
        let previous = cachedLookup(word: word, source: source, target: target, provider: provider)

        async let resolvedImage = resolveMedia(
            imageRemoved ? nil : remoteImageURL,
            previousPath: imageRemoved ? nil : previous?.imageRelativePath,
            previousRemote: imageRemoved ? nil : previous?.remoteImageURL,
            folder: imagesURL, kind: .image
        )
        async let resolvedAudio = resolveMedia(remoteAudioURL, previousPath: previous?.audioRelativePath, previousRemote: previous?.remoteAudioURL, folder: audioURL, kind: .audio)
        let image = await resolvedImage
        let audio = await resolvedAudio

        let entry = CachedLookup(
            word: normalized,
            sourceLanguage: source,
            targetLanguage: target,
            provider: provider,
            pronunciation: pronunciation,
            partOfSpeech: partOfSpeech,
            definition: definition,
            example: example,
            synonyms: synonyms,
            translation: translation,
            imageRelativePath: image.path,
            imageRemoved: imageRemoved,
            audioRelativePath: audio.path,
            remoteImageURL: image.remote,
            remoteAudioURL: audio.remote,
            cachedAt: Date()
        )

        let file = lookupsURL.appendingPathComponent(lookupFileName(word: normalized, source: source, target: target, provider: provider))
        if let data = try? encoder.encode(entry) {
            try? data.write(to: file, options: .atomic)
        }
        refreshStats()
    }

    /// Ensures a remote media URL is on disk; returns a file URL when possible.
    func localMediaURL(for remote: URL?, kind: MediaKind) async -> URL? {
        guard let remote else { return nil }
        if remote.isFileURL, fileManager.fileExists(atPath: remote.path) {
            return remote
        }
        let folder = kind == .image ? imagesURL : audioURL
        if let rel = await cacheMedia(remote, into: folder, kind: kind) {
            return rootURL.appendingPathComponent(rel)
        }
        return remote // fall back to remote if download failed
    }

    func clearAll() {
        for name in ["lookups", "media"] {
            let url = rootURL.appendingPathComponent(name, isDirectory: true)
            try? fileManager.removeItem(at: url)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try? fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: audioURL, withIntermediateDirectories: true)
        refreshStats()
    }

    func refreshStats() {
        byteSize = directorySize(rootURL)
        entryCount = (try? fileManager.contentsOfDirectory(atPath: lookupsURL.path))?.count ?? 0
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    // MARK: - Helpers

    enum MediaKind { case image, audio }

    private func normalizedWord(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func lookupFileName(word: String, source: String, target: String, provider: String) -> String {
        let key = "\(normalizedWord(word))|\(source)|\(target)|\(provider)"
        return stableHash(key) + ".json"
    }

    private func stableHash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func resolveMedia(
        _ incoming: URL?,
        previousPath: String?,
        previousRemote: URL?,
        folder: URL,
        kind: MediaKind
    ) async -> (path: String?, remote: URL?) {
        guard let incoming else {
            return (previousPath, previousRemote)
        }
        guard let path = await cacheMedia(incoming, into: folder, kind: kind) else {
            return (previousPath, previousRemote)
        }
        let remote: URL?
        if incoming.isFileURL {
            let root = rootURL.path
            remote = incoming.path.hasPrefix(root) ? previousRemote : nil
        } else {
            remote = incoming
        }
        return (path, remote)
    }

    private func cacheMedia(_ remote: URL?, into folder: URL, kind: MediaKind) async -> String? {
        guard let remote, !remote.isFileURL else {
            // Already local — copy into our cache if it's outside.
            if let remote, remote.isFileURL {
                return relativizeExisting(remote, preferredFolder: folder, kind: kind)
            }
            return nil
        }

        let ext = preferredExtension(for: remote, kind: kind)
        let filename = stableHash(remote.absoluteString) + "." + ext
        let destination = folder.appendingPathComponent(filename)

        if fileManager.fileExists(atPath: destination.path) {
            return relativePath(for: destination)
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                return nil
            }
            try data.write(to: destination, options: .atomic)
            return relativePath(for: destination)
        } catch {
            NSLog("Lanki cache: failed to download \(remote) — \(error.localizedDescription)")
            return nil
        }
    }

    private func relativizeExisting(_ fileURL: URL, preferredFolder: URL, kind: MediaKind) -> String? {
        let rootPath = rootURL.path
        if fileURL.path.hasPrefix(rootPath) {
            return relativePath(for: fileURL)
        }
        let ext = preferredExtension(for: fileURL, kind: kind)
        let dest = preferredFolder.appendingPathComponent(stableHash(fileURL.path) + "." + ext)
        if !fileManager.fileExists(atPath: dest.path) {
            try? fileManager.copyItem(at: fileURL, to: dest)
        }
        return fileManager.fileExists(atPath: dest.path) ? relativePath(for: dest) : nil
    }

    private func preferredExtension(for url: URL, kind: MediaKind) -> String {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 5 { return ext }
        return kind == .image ? "jpg" : "mp3"
    }

    private func relativePath(for fileURL: URL) -> String {
        let root = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        if fileURL.path.hasPrefix(root) {
            return String(fileURL.path.dropFirst(root.count))
        }
        return fileURL.lastPathComponent
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }
}
