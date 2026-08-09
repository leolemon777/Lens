@preconcurrency import AVFoundation
import Foundation
import ScreenTraceCore

@MainActor
final class VideoEditorPlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTimeSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var sourceURL: URL?
    private var generation = 0
    private var loadTask: Task<Void, Never>?

    func load(sourceURL: URL, timeline: VideoEditTimeline) {
        self.sourceURL = sourceURL
        loadTask?.cancel()
        generation += 1
        let generation = generation
        let preservedTime = currentTimeSeconds
        player.pause()
        isPlaying = false
        isLoading = true
        errorMessage = nil

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let composition = try await VideoTimelineCompositionBuilder().build(
                    inputURL: sourceURL,
                    timeline: timeline,
                    includesVideo: true,
                    includesAudio: true,
                    requiresVideo: true
                )
                let duration = try await composition.load(.duration).seconds
                guard self.generation == generation else { return }
                durationSeconds = max(duration.isFinite ? duration : 0, 0)
                player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
                seek(to: min(preservedTime, durationSeconds))
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                player.replaceCurrentItem(with: nil)
                durationSeconds = 0
                currentTimeSeconds = 0
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func reload(timeline: VideoEditTimeline) {
        guard let sourceURL else { return }
        load(sourceURL: sourceURL, timeline: timeline)
    }

    func togglePlayback() {
        guard player.currentItem != nil, !isLoading else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if durationSeconds > 0,
               currentTimeSeconds >= durationSeconds - 0.02 {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds.isFinite ? seconds : 0, 0), durationSeconds)
        currentTimeSeconds = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func refreshTime() {
        guard !isLoading else { return }
        let time = player.currentTime().seconds
        if time.isFinite {
            currentTimeSeconds = min(max(time, 0), durationSeconds)
        }
        isPlaying = player.timeControlStatus == .playing
    }

    func stop() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        isPlaying = false
        isLoading = false
    }
}
