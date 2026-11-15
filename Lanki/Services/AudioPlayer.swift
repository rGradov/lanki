import AVFoundation
import Combine
import AppKit

/// Plays remote dictionary pronunciations and publishes UI-friendly state
/// so the popup can show a spinner while the first buffer loads.
@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var activeURL: URL?

    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?

    /// Invoked once if the clip can't be loaded/played (used for TTS fallback).
    private var onFailure: (() -> Void)?

    private init() {}

    func play(_ url: URL, onFailure: (() -> Void)? = nil) {
        // Re-tap while already loading/playing the same clip — ignore.
        if activeURL == url, state == .loading || state == .playing { return }

        tearDown()
        self.onFailure = onFailure
        activeURL = url
        state = .loading

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                self?.handleStatus(item.status, error: item.error)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.handleTimeControl(player.timeControlStatus)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.state = .idle
                self?.player?.seek(to: .zero)
            }
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markFailed()
            }
        }

        player.play()
    }

    func stop() {
        tearDown()
        state = .idle
        activeURL = nil
    }

    // MARK: - Private

    private func handleStatus(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            // Prefer timeControlStatus for loading→playing, but if already playing, sync.
            if player?.timeControlStatus == .playing {
                state = .playing
            }
        case .failed:
            NSLog("Lanki audio failed: \(error?.localizedDescription ?? "unknown")")
            markFailed()
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleTimeControl(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            // Buffering / first load.
            if state != .failed { state = .loading }
        case .playing:
            state = .playing
            onFailure = nil // successfully started — no fallback needed
        case .paused:
            // End-of-track seeks to zero and pauses — treat as idle unless failed.
            if state != .failed { state = .idle }
        @unknown default:
            break
        }
    }

    /// Marks the current clip as failed and fires the fallback exactly once.
    private func markFailed() {
        state = .failed
        let fallback = onFailure
        onFailure = nil
        fallback?()
    }

    private func tearDown() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failedObserver { NotificationCenter.default.removeObserver(failedObserver) }
        endObserver = nil
        failedObserver = nil
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        statusObservation = nil
        timeControlObservation = nil
        player?.pause()
        player = nil
        onFailure = nil
    }
}
