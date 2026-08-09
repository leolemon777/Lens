@preconcurrency import AVFoundation
import Foundation
import ScreenTraceCore

@MainActor
final class VideoEditorPlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTimeSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    @Published private(set) var videoAspectRatio = 16.0 / 9.0
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
        videoAspectRatio = 16.0 / 9.0

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
                let aspectRatio = await VideoEditorMediaInspector.aspectRatio(
                    for: sourceURL
                )
                guard self.generation == generation else { return }
                durationSeconds = max(duration.isFinite ? duration : 0, 0)
                videoAspectRatio = min(max(
                    aspectRatio.isFinite ? aspectRatio : 16.0 / 9.0,
                    0.25
                ), 4)
                player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
                seek(to: min(preservedTime, durationSeconds))
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                player.replaceCurrentItem(with: nil)
                durationSeconds = 0
                videoAspectRatio = 16.0 / 9.0
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

    func pause() {
        player.pause()
        isPlaying = false
        refreshTime()
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

private enum VideoEditorMediaInspector {
    nonisolated static func aspectRatio(for sourceURL: URL) async -> Double {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await videoTrack.load(.naturalSize),
              let transform = try? await videoTrack.load(.preferredTransform) else {
            return 16.0 / 9.0
        }
        let oriented = CGRect(origin: .zero, size: naturalSize)
            .applying(transform)
            .standardized
        return Double(abs(oriented.width) / max(abs(oriented.height), 1))
    }
}
