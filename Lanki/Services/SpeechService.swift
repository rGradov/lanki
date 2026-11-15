import AVFoundation
import Combine

/// System text-to-speech, used as a fallback when a dictionary audio clip is
/// missing or fails to load. Can both speak aloud (for the popup) and render a
/// `.wav` file on disk (to embed on the Anki card).
@MainActor
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    /// The text currently being spoken aloud, or nil when idle. The popup's
    /// pronunciation button observes this to animate the speaker glyph.
    @Published private(set) var speakingText: String?

    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Live playback

    func speak(_ text: String, language: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = SpeechService.voice(for: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingText = text
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingText = nil
    }

    // MARK: - WAV rendering (for Anki)

    /// Renders `text` to a 16-bit PCM `.wav` file and returns its URL, or nil
    /// on failure. The file lives in the temporary directory; the caller is
    /// responsible for attaching / cleaning it up.
    func synthesizeWAV(text: String, language: String?) async -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await TTSWavWriter().render(text: trimmed, voice: SpeechService.voice(for: language))
    }

    // MARK: - Voice selection

    /// Best available voice for a language code such as "en" or "ru".
    private static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        guard let language, !language.isEmpty else {
            return AVSpeechSynthesisVoice(language: nil)
        }
        if let exact = AVSpeechSynthesisVoice(language: language) {
            return exact
        }
        // Fall back to the first installed voice whose language starts with the code.
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(language) }
            ?? AVSpeechSynthesisVoice(language: nil)
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingText = nil }
    }
}

/// One-shot helper that owns an `AVSpeechSynthesizer` for the duration of a
/// `write(_:)` render so it isn't deallocated mid-flight. Not main-actor bound;
/// its state is only touched from the (serial) synthesis callback.
private final class TTSWavWriter: @unchecked Sendable {
    private var synthesizer: AVSpeechSynthesizer?
    private var audioFile: AVAudioFile?
    private var finished = false

    func render(text: String, voice: AVSpeechSynthesisVoice?) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let synth = AVSpeechSynthesizer()
            synthesizer = synth

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lanki_tts_\(UUID().uuidString).wav")

            synth.write(utterance) { [weak self] buffer in
                guard let self else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }

                // An empty final buffer signals the end of synthesis.
                if pcm.frameLength == 0 {
                    self.finish(continuation, url: self.audioFile != nil ? url : nil)
                    return
                }

                do {
                    if self.audioFile == nil {
                        self.audioFile = try AVAudioFile(
                            forWriting: url,
                            settings: pcm.format.settings,
                            commonFormat: pcm.format.commonFormat,
                            interleaved: pcm.format.isInterleaved
                        )
                    }
                    try self.audioFile?.write(from: pcm)
                } catch {
                    NSLog("Lanki TTS WAV write failed: \(error.localizedDescription)")
                    self.finish(continuation, url: nil)
                }
            }
        }
    }

    private func finish(_ continuation: CheckedContinuation<URL?, Never>, url: URL?) {
        guard !finished else { return }
        finished = true
        audioFile = nil
        synthesizer = nil
        continuation.resume(returning: url)
    }
}
