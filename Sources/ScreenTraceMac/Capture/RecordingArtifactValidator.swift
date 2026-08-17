@preconcurrency import AVFoundation
import Foundation
import ScreenTraceCore

struct RecordingVideoMetrics: Equatable, Sendable {
    let sampleCount: Int
    let measuredFramesPerSecond: Double?
    let p95FrameIntervalMilliseconds: Double?
}

struct RecordingArtifactValidator: Sendable {
    let store: TraceProjectStore

    func validate(
        session: RecordingTraceSession,
        requestedFramesPerSecond: Int,
        eventSnapshot: EventCaptureSnapshot,
        capturePerformance: CapturePerformanceSnapshot?,
        interruptedOptionalTracks: Set<RecordingRawTrackKind> = []
    ) async -> RecordingHealthReport {
        async let videoMetricsTask = Self.inspectVideo(at: session.videoURL)
        async let trackIntegrityTask = Self.inspectTrackIntegrity(session: session)
        async let countsTask = Self.readEventCounts(session: session)
        let plan = try? store.loadAutoEditPlan(from: session.packageURL)
        let videoMetrics = await videoMetricsTask
        let trackIntegrity = await trackIntegrityTask
        let counts = await countsTask

        let effectiveCameraKeyframeCount = plan?.camera.keyframes.filter {
            $0.reason != .baseline
        }.count ?? 0
        let mediaDuration = (try? store.loadManifest(from: session.packageURL))?
            .durationSeconds ?? plan?.camera.keyframes.last?.time ?? 0
        let cameraMotionComfort = plan.map {
            CameraMotionComfortAnalyzer.analyze(
                camera: $0.camera,
                durationSeconds: mediaDuration
            )
        }
        let cursorKeyframeCount = plan?.cursor.keyframes.count ?? 0
        let clickPulseCount = plan?.interaction?.clickPulses.count ?? 0
        let requestedFramesPerSecond = max(requestedFramesPerSecond, 1)
        let frameRateThreshold = requestedFramesPerSecond >= 60
            ? 58.0
            : Double(requestedFramesPerSecond) * 0.95
        let measuredFramesPerSecond = videoMetrics?.measuredFramesPerSecond
        let p95FrameIntervalMilliseconds = videoMetrics?.p95FrameIntervalMilliseconds
        let droppedFrameCount = capturePerformance?.droppedFrameCount ?? 0

        var warnings: [RecordingHealthWarning] = []
        let videoStatus: RecordingComponentStatus
        if let measuredFramesPerSecond {
            if measuredFramesPerSecond < frameRateThreshold {
                warnings.append(.measuredFrameRateBelowRequest)
                videoStatus = .degraded
            } else {
                videoStatus = .healthy
            }
        } else {
            videoStatus = .failed
        }
        if let p95FrameIntervalMilliseconds,
           p95FrameIntervalMilliseconds > 34,
           requestedFramesPerSecond >= 60 {
            warnings.append(.highFrameIntervalVariance)
        }
        if droppedFrameCount > 0 {
            warnings.append(.droppedVideoFrames)
        }

        let eventStatus: RecordingComponentStatus
        switch eventSnapshot.health {
        case .degraded:
            eventStatus = .degraded
            warnings.append(.eventCaptureDegraded)
            if counts.pointer == 0 {
                warnings.append(.pointerTrackEmpty)
            }
        case .healthy:
            eventStatus = .healthy
        case .checking, .waitingForActivity:
            eventStatus = counts.pointer > 0 || counts.click > 0 ? .healthy : .notMeasured
        }

        if counts.pointer > 0, cursorKeyframeCount == 0 {
            warnings.append(.cursorPlanNotGenerated)
        }
        if counts.click > 0, clickPulseCount == 0 {
            warnings.append(.clickEffectsNotGenerated)
        }
        if counts.click > 0, effectiveCameraKeyframeCount == 0 {
            warnings.append(.automaticCameraNotGenerated)
        }
        if cameraMotionComfort?.isComfortable == false {
            warnings.append(.cameraMotionMayCauseDiscomfort)
        }
        if !trackIntegrity.missingRequestedTracks.isEmpty {
            warnings.append(.requestedMediaTrackMissing)
        }
        if !trackIntegrity.outOfSyncTracks.isEmpty {
            warnings.append(.rawTrackDurationDrift)
        }
        warnings.append(contentsOf: Self.optionalTrackInterruptionWarnings(
            for: interruptedOptionalTracks
        ))

        return RecordingHealthReport(
            requestedFramesPerSecond: requestedFramesPerSecond,
            measuredFramesPerSecond: measuredFramesPerSecond,
            p95FrameIntervalMilliseconds: p95FrameIntervalMilliseconds,
            droppedFrameCount: droppedFrameCount,
            videoStatus: videoStatus,
            eventStatus: eventStatus,
            pointerEventCount: counts.pointer,
            clickEventCount: counts.click,
            keyboardEventCount: counts.keyboard,
            windowEventCount: counts.window,
            effectiveCameraKeyframeCount: effectiveCameraKeyframeCount,
            cursorKeyframeCount: cursorKeyframeCount,
            clickPulseCount: clickPulseCount,
            cameraMotionComfort: cameraMotionComfort,
            rawTrackIntegrity: trackIntegrity,
            warnings: warnings
        )
    }

    static func optionalTrackInterruptionWarnings(
        for tracks: Set<RecordingRawTrackKind>
    ) -> [RecordingHealthWarning] {
        RecordingRawTrackKind.allCases.compactMap { track -> RecordingHealthWarning? in
            guard tracks.contains(track) else { return nil }
            switch track {
            case .microphone: return .microphoneInterrupted
            case .camera: return .cameraInterrupted
            case .systemAudio: return nil
            }
        }
    }

    static func inspectTrackIntegrity(
        session: RecordingTraceSession,
        durationToleranceSeconds: Double = 0.15
    ) async -> RecordingTrackIntegrityReport {
        let requestedSystemAudio = session.manifest.assets.contains {
            $0.role == .systemAudio
        }
        let requestedMicrophone = session.microphoneURL != nil
        let requestedCamera = session.cameraURL != nil
        async let screenDurationTask = trackDuration(
            at: session.videoURL,
            mediaType: .video
        )
        async let systemDurationTask = trackDuration(
            at: requestedSystemAudio ? session.videoURL : nil,
            mediaType: .audio
        )
        async let microphoneDurationTask = trackDuration(
            at: session.microphoneURL,
            mediaType: .audio
        )
        async let cameraDurationTask = trackDuration(
            at: session.cameraURL,
            mediaType: .video
        )
        return await RecordingTrackIntegrityReport(
            screenVideoDurationSeconds: screenDurationTask,
            systemAudioDurationSeconds: systemDurationTask,
            microphoneDurationSeconds: microphoneDurationTask,
            cameraDurationSeconds: cameraDurationTask,
            requestedSystemAudio: requestedSystemAudio,
            requestedMicrophone: requestedMicrophone,
            requestedCamera: requestedCamera,
            durationToleranceSeconds: durationToleranceSeconds
        )
    }

    private static func trackDuration(
        at url: URL?,
        mediaType: AVMediaType
    ) async -> Double? {
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
                return nil
            }
            let timeRange = try await track.load(.timeRange)
            let seconds = timeRange.duration.seconds
            return timeRange.duration.isNumeric && seconds.isFinite && seconds > 0
                ? seconds
                : nil
        } catch {
            return nil
        }
    }

    static func inspectVideo(at url: URL) async -> RecordingVideoMetrics? {
        await Task.detached(priority: .utility) {
            do {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return nil }
                let trackRange = try await track.load(.timeRange)
                let duration = trackRange.duration.seconds
                guard duration.isFinite, duration > 0 else { return nil }
                // A one-hour 60 FPS file contains 216,000 samples. Scanning and
                // sorting every timestamp on the stop path delays access to the
                // raw recording. Short clips retain exhaustive verification;
                // long clips use bounded beginning/middle/end media windows.
                let ranges = Self.verificationRanges(
                    trackRange: trackRange,
                    durationSeconds: duration
                )
                var sampleCount = 0
                var intervals: [Double] = []
                for range in ranges {
                    let times = try Self.readPresentationTimes(
                        asset: asset,
                        track: track,
                        timeRange: range
                    )
                    sampleCount += times.count
                    intervals.append(contentsOf: zip(times, times.dropFirst()).compactMap {
                        let interval = $1 - $0
                        return interval.isFinite && interval > 0 ? interval : nil
                    })
                }
                guard !intervals.isEmpty else { return nil }
                guard let medianInterval = percentile(intervals, fraction: 0.5),
                      medianInterval > 0 else { return nil }
                // Window boundaries can contain a partial GOP interval. The
                // median represents steady-state pacing without allowing that
                // keyframe pre-roll artifact to skew a long recording's FPS.
                let measuredFramesPerSecond = 1 / medianInterval
                return RecordingVideoMetrics(
                    sampleCount: sampleCount,
                    measuredFramesPerSecond: measuredFramesPerSecond,
                    p95FrameIntervalMilliseconds: percentile(
                        intervals,
                        fraction: 0.95
                    ).map { $0 * 1_000 }
                )
            } catch {
                return nil
            }
        }.value
    }

    private static func verificationRanges(
        trackRange: CMTimeRange,
        durationSeconds: Double
    ) -> [CMTimeRange] {
        guard durationSeconds > 30 else { return [trackRange] }
        let windowSeconds = 2.0
        let availableStartSpan = max(durationSeconds - windowSeconds, 0)
        let baseStart = trackRange.start.seconds
        return [0.0, 0.25, 0.5, 0.75, 1.0].map { fraction in
            CMTimeRange(
                start: CMTime(
                    seconds: baseStart + availableStartSpan * fraction,
                    preferredTimescale: 60_000
                ),
                duration: CMTime(
                    seconds: min(windowSeconds, durationSeconds),
                    preferredTimescale: 60_000
                )
            )
        }
    }

    private static func readPresentationTimes(
        asset: AVAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange
    ) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var times: [Double] = []
        let lowerBound = timeRange.start.seconds - 0.000_001
        let upperBound = timeRange.end.seconds + 0.000_001
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let seconds = sampleBuffer.presentationTimeStamp.seconds
            // H.264 readers may emit keyframe pre-roll outside reader.timeRange.
            // Those frames are required for decoding, not part of the pacing
            // window being measured.
            if seconds.isFinite,
               seconds >= lowerBound,
               seconds <= upperBound {
                times.append(seconds)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? NSError(
                domain: "ScreenTrace.RecordingArtifactValidator",
                code: 1
            )
        }
        // Passthrough H.264 samples can arrive in decode order because of
        // B-frame reordering. Frame pacing is a presentation-time metric.
        return times.sorted()
    }

    private static func readEventCounts(
        session: RecordingTraceSession
    ) async -> (pointer: Int, click: Int, keyboard: Int, window: Int) {
        await Task.detached(priority: .utility) {
            (
                (try? TraceEventReader.read(
                    PointerEvent.self,
                    from: session.pointerEventsURL
                ).count) ?? 0,
                (try? TraceEventReader.read(
                    ClickEvent.self,
                    from: session.clickEventsURL
                ).count) ?? 0,
                (try? TraceEventReader.read(
                    KeyboardEvent.self,
                    from: session.keyboardEventsURL
                ).count) ?? 0,
                (try? TraceEventReader.read(
                    WindowEvent.self,
                    from: session.windowEventsURL
                ).count) ?? 0
            )
        }.value
    }

    private static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(
            (Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded(.up)
        )
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
