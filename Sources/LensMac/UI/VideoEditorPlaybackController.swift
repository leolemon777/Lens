@preconcurrency import AVFoundation
import Foundation
import LensCore

@MainActor
final class VideoEditorPlaybackClock: ObservableObject {
    @Published private(set) var currentTimeSeconds = 0.0

    func update(_ seconds: Double) {
        let normalized = max(seconds.isFinite ? seconds : 0, 0)
        guard abs(normalized - currentTimeSeconds) > 0.000_1 else { return }
        currentTimeSeconds = normalized
    }
}

@MainActor
final class VideoEditorPlaybackController: ObservableObject {
    static let timelineReloadDebounce = Duration.milliseconds(120)

    let player = AVPlayer()
    let clock = VideoEditorPlaybackClock()

    var currentTimeSeconds: Double { clock.currentTimeSeconds }
    @Published private(set) var durationSeconds = 0.0
    @Published private(set) var videoAspectRatio = 16.0 / 9.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isShowingRenderedPreview = false
    @Published private(set) var canShowRenderedPreview = false
    @Published private(set) var waveformPeaks: [Float] = []

    private var rawSourceURL: URL?
    private var rawTimeline: VideoEditTimeline?
    private var renderedPreviewURL: URL?
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var reloadDebounceTask: Task<Void, Never>?
    private var interactiveSeekTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var pendingInteractiveSeekTime: Double?
    private var aspectRatioCache: [URL: Double] = [:]

    private static let interactiveSeekDebounce = Duration.milliseconds(16)

    func load(
        sourceURL: URL,
        timeline: VideoEditTimeline,
        renderedPreviewURL: URL? = nil
    ) {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = nil
        rawSourceURL = sourceURL
        rawTimeline = timeline
        self.renderedPreviewURL = renderedPreviewURL
        canShowRenderedPreview = renderedPreviewURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        if let renderedPreviewURL, canShowRenderedPreview {
            loadRenderedPreview(renderedPreviewURL)
        } else {
            loadRaw(sourceURL: sourceURL, timeline: timeline)
        }
        refreshWaveform(from: sourceURL)
    }

    private func refreshWaveform(from url: URL) {
        waveformTask?.cancel()
        waveformPeaks = []
        waveformTask = Task { @MainActor [weak self] in
            let peaks = await TimelineWaveformSampler.peaks(from: url)
            guard !Task.isCancelled,
                  let self,
                  self.rawSourceURL == url else { return }
            self.waveformPeaks = peaks
            self.waveformTask = nil
        }
    }

    private func loadRaw(sourceURL: URL, timeline: VideoEditTimeline) {
        loadTask?.cancel()
        generation += 1
        let generation = generation
        let preservedTime = currentTimeSeconds
        player.pause()
        isPlaying = false
        isLoading = true
        errorMessage = nil
        isShowingRenderedPreview = false
        videoAspectRatio = 16.0 / 9.0

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let package = try await VideoTimelineCompositionBuilder().buildPackage(
                    inputURL: sourceURL,
                    timeline: timeline,
                    includesVideo: true,
                    includesAudio: true,
                    requiresVideo: true
                )
                let duration = try await package.composition.load(.duration).seconds
                let aspectRatio = await cachedAspectRatio(for: sourceURL)
                guard self.generation == generation else { return }
                durationSeconds = max(duration.isFinite ? duration : 0, 0)
                videoAspectRatio = min(max(
                    aspectRatio.isFinite ? aspectRatio : 16.0 / 9.0,
                    0.25
                ), 4)
                let item = AVPlayerItem(asset: package.composition)
                item.videoComposition = package.videoComposition
                item.audioMix = package.audioMix
                player.replaceCurrentItem(with: item)
                seek(to: min(preservedTime, durationSeconds))
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                player.replaceCurrentItem(with: nil)
                durationSeconds = 0
                videoAspectRatio = 16.0 / 9.0
                clock.update(0)
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func reload(timeline: VideoEditTimeline) {
        rawTimeline = timeline
        guard let rawSourceURL else { return }
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.timelineReloadDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            reloadDebounceTask = nil
            loadRaw(sourceURL: rawSourceURL, timeline: timeline)
        }
    }

    func updateRenderedPreview(
        url: URL,
        timeline: VideoEditTimeline,
        switchesImmediately: Bool = true
    ) {
        renderedPreviewURL = url
        rawTimeline = timeline
        canShowRenderedPreview = FileManager.default.fileExists(atPath: url.path)
        guard canShowRenderedPreview, switchesImmediately else { return }
        loadRenderedPreview(url)
    }

    func togglePreviewMode() {
        if isShowingRenderedPreview {
            guard let rawSourceURL, let rawTimeline else { return }
            loadRaw(sourceURL: rawSourceURL, timeline: rawTimeline)
        } else if let renderedPreviewURL, canShowRenderedPreview {
            loadRenderedPreview(renderedPreviewURL)
        }
    }

    func showRawPreview() {
        pause()
        guard isShowingRenderedPreview,
              let rawSourceURL,
              let rawTimeline else { return }
        loadRaw(sourceURL: rawSourceURL, timeline: rawTimeline)
    }

    /// The generated movie reflects the last saved plan. Once the plan changes,
    /// keeping that movie selectable would make inspector controls appear broken.
    func invalidateRenderedPreview() {
        if canShowRenderedPreview {
            canShowRenderedPreview = false
        }
        // When the raw preview is already active, changing a slider should not
        // pause or reload it. This makes repeated plan ticks effectively free.
        if isShowingRenderedPreview {
            showRawPreview()
        }
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

    func seek(to seconds: Double, coalescing: Bool = false) {
        let clamped = min(max(seconds.isFinite ? seconds : 0, 0), durationSeconds)
        clock.update(clamped)
        if coalescing {
            pendingInteractiveSeekTime = clamped
            scheduleInteractiveSeekFlush()
        } else {
            flushInteractiveSeek()
            performSeek(to: clamped)
        }
    }

    private func scheduleInteractiveSeekFlush() {
        guard interactiveSeekTask == nil else { return }
        interactiveSeekTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.interactiveSeekDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.interactiveSeekTask = nil
            self.flushInteractiveSeek()
        }
    }

    private func flushInteractiveSeek() {
        interactiveSeekTask?.cancel()
        interactiveSeekTask = nil
        guard let pendingInteractiveSeekTime else { return }
        self.pendingInteractiveSeekTime = nil
        performSeek(to: pendingInteractiveSeekTime)
    }

    private func performSeek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func step(byFrames frames: Int) {
        seek(to: currentTimeSeconds + Double(frames) / 30)
        settlePlayhead()
    }

    func nudge(bySeconds seconds: Double) {
        seek(to: currentTimeSeconds + seconds)
        settlePlayhead()
    }

    func seekToStart() {
        seek(to: 0)
        settlePlayhead()
    }

    func seekToEnd() {
        seek(to: durationSeconds)
        settlePlayhead()
    }

    func refreshTime() {
        guard !isLoading else { return }
        let time = player.currentTime().seconds
        if time.isFinite {
            clock.update(min(max(time, 0), durationSeconds))
        }
        let playing = player.timeControlStatus == .playing
        if isPlaying != playing { isPlaying = playing }
    }

    /// High-frequency clock changes stay inside lightweight playback views.
    /// Call this after an interactive seek ends so time-dependent editor
    /// controls refresh once without laying out the full inspector every frame.
    func settlePlayhead() {
        flushInteractiveSeek()
        objectWillChange.send()
    }

    func stop() {
        generation += 1
        reloadDebounceTask?.cancel()
        reloadDebounceTask = nil
        interactiveSeekTask?.cancel()
        interactiveSeekTask = nil
        pendingInteractiveSeekTime = nil
        waveformTask?.cancel()
        waveformTask = nil
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        isPlaying = false
        isLoading = false
    }

    private func loadRenderedPreview(_ url: URL) {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = nil
        loadTask?.cancel()
        generation += 1
        let generation = generation
        let preservedTime = currentTimeSeconds
        player.pause()
        isPlaying = false
        isLoading = true
        isShowingRenderedPreview = true
        errorMessage = nil
        videoAspectRatio = 16.0 / 9.0

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration).seconds
                let aspectRatio = await cachedAspectRatio(for: url)
                guard self.generation == generation else { return }
                durationSeconds = max(duration.isFinite ? duration : 0, 0)
                videoAspectRatio = min(max(
                    aspectRatio.isFinite ? aspectRatio : 16.0 / 9.0,
                    0.25
                ), 4)
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                seek(to: min(preservedTime, durationSeconds))
                isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == generation else { return }
                isShowingRenderedPreview = false
                canShowRenderedPreview = false
                if let rawSourceURL, let rawTimeline {
                    loadRaw(sourceURL: rawSourceURL, timeline: rawTimeline)
                } else {
                    player.replaceCurrentItem(with: nil)
                    durationSeconds = 0
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cachedAspectRatio(for sourceURL: URL) async -> Double {
        let key = sourceURL.standardizedFileURL
        if let cached = aspectRatioCache[key] {
            return cached
        }
        let inspected = await VideoEditorMediaInspector.aspectRatio(for: key)
        aspectRatioCache[key] = inspected
        return inspected
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
