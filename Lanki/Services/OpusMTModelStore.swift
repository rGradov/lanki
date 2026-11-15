import Foundation

/// Downloads the small Opus-MT English ↔ Russian models into Application Support.
/// The weights are not part of the app bundle.
@MainActor
final class OpusMTModelStore: ObservableObject {
    static let shared = OpusMTModelStore()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isReady = false

    nonisolated static let rootURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Lanki", isDirectory: true)
            .appendingPathComponent("OpusMT", isDirectory: true)
    }()

    private var downloadTask: Task<Void, Never>?

    private init() {
        isReady = Self.modelsReady()
    }

    func download() {
        guard downloadTask == nil else { return }
        phase = .downloading(0)
        downloadTask = Task {
            do {
                try await Self.fetchAll { fraction in
                    Task { @MainActor in
                        self.phase = .downloading(fraction)
                    }
                }
                isReady = true
                phase = .idle
            } catch {
                isReady = Self.modelsReady()
                phase = .failed(error.localizedDescription)
            }
            downloadTask = nil
        }
    }

    func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        try? FileManager.default.removeItem(at: Self.rootURL)
        OpusMTEngine.shared.reset()
        isReady = false
        phase = .idle
    }

    nonisolated static func directory(for direction: OpusDirection) -> URL {
        rootURL.appendingPathComponent(direction.folder, isDirectory: true)
    }

    nonisolated static func modelsReady() -> Bool {
        OpusDirection.allCases.allSatisfy { directionIsReady($0) }
    }

    nonisolated static func directionIsReady(_ direction: OpusDirection) -> Bool {
        let folder = directory(for: direction)
        return OpusRemoteFile.manifest.allSatisfy { file in
            let url = folder.appendingPathComponent(file.localName)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size >= file.minimumBytes
        }
    }

    // MARK: - Download

    private static func fetchAll(progress: @escaping (Double) -> Void) async throws {
        let directions = OpusDirection.allCases
        let files = OpusRemoteFile.manifest
        let total = directions.count * files.count
        var index = 0
        for direction in directions {
            let folder = directory(for: direction)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                try Task.checkCancellation()
                let destination = folder.appendingPathComponent(file.localName)
                if fileExists(destination, minimumBytes: file.minimumBytes) {
                    index += 1
                    progress(Double(index) / Double(total))
                    continue
                }
                let remote = url(repo: direction.repo, path: file.remotePath)
                let temp = try await download(remote) { fraction in
                    progress((Double(index) + fraction) / Double(total))
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temp, to: destination)
                index += 1
                progress(Double(index) / Double(total))
            }
            try patchTokenizerConfig(in: folder)
        }
    }

    private static func url(repo: String, path: String) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)")!
    }

    private static func fileExists(_ url: URL, minimumBytes: Int) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size >= minimumBytes
    }

    /// swift-transformers has no Marian class. The file is a Unigram tokenizer, which that
    /// package loads under the XLM-RoBERTa name.
    private static func patchTokenizerConfig(in folder: URL) throws {
        let url = folder.appendingPathComponent("tokenizer_config.json")
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        object["tokenizer_class"] = "XLMRobertaTokenizer"
        let patched = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try patched.write(to: url, options: .atomic)
    }

    private static func download(_ url: URL, fraction: @escaping (Double) -> Void) async throws -> URL {
        let box = DownloadBox(onFraction: fraction)
        return try await box.download(url)
    }
}

enum OpusDirection: CaseIterable {
    case enToRu
    case ruToEn

    var folder: String {
        switch self {
        case .enToRu: return "en-ru"
        case .ruToEn: return "ru-en"
        }
    }

    var repo: String {
        switch self {
        case .enToRu: return "Xenova/opus-mt-en-ru"
        case .ruToEn: return "Xenova/opus-mt-ru-en"
        }
    }

    static func matching(from source: String, to target: String) -> OpusDirection? {
        switch (source.lowercased(), target.lowercased()) {
        case ("en", "ru"): return .enToRu
        case ("ru", "en"): return .ruToEn
        default: return nil
        }
    }
}

struct OpusRemoteFile {
    let localName: String
    let remotePath: String
    let minimumBytes: Int

    static let manifest: [OpusRemoteFile] = [
        OpusRemoteFile(localName: "encoder.onnx", remotePath: "onnx/encoder_model_int8.onnx", minimumBytes: 1_000_000),
        OpusRemoteFile(localName: "decoder.onnx", remotePath: "onnx/decoder_model_int8.onnx", minimumBytes: 1_000_000),
        OpusRemoteFile(localName: "tokenizer.json", remotePath: "tokenizer.json", minimumBytes: 10_000),
        OpusRemoteFile(localName: "tokenizer_config.json", remotePath: "tokenizer_config.json", minimumBytes: 20),
        OpusRemoteFile(localName: "config.json", remotePath: "config.json", minimumBytes: 20)
    ]
}

private final class DownloadBox: NSObject, URLSessionDownloadDelegate {
    private let onFraction: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumed = false

    init(onFraction: @escaping (Double) -> Void) {
        self.onFraction = onFraction
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.setValue("Lanki", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onFraction(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200...299).contains(status) else {
            finish(session, result: .failure(URLError(.badServerResponse)))
            return
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(session, result: .success(destination))
        } catch {
            finish(session, result: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(session, result: .failure(error))
    }

    private func finish(_ session: URLSession, result: Result<URL, Error>) {
        guard !resumed else { return }
        resumed = true
        continuation?.resume(with: result)
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}
