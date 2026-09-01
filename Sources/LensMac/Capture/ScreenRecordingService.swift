import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit
import LensCore

enum RecordingOptionalTrack: String, Sendable, CaseIterable, Hashable {
    case microphone
    case camera
}

/// Per-recording availability for optional capture tracks. A disconnected
/// microphone or camera must never prevent the primary screen recording from
/// pausing, resuming, or being finalized. This state is deliberately reset for
/// every new recording so the user's next session probes devices again.
struct RecordingOptionalTrackAvailability: Equatable, Sendable {
    private(set) var disabledTracks: Set<RecordingOptionalTrack> = []

    @discardableResult
    mutating func disable(_ track: RecordingOptionalTrack) -> Bool {
        disabledTracks.insert(track).inserted
    }

    func isEnabled(
        _ track: RecordingOptionalTrack,
        requestedOptions: ScreenRecordingOptions
    ) -> Bool {
        guard !disabledTracks.contains(track) else { return false }
        switch track {
        case .microphone: return requestedOptions.capturesMicrophone
        case .camera: return requestedOptions.capturesCamera
        }
    }
}

enum ScreenRecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case displayUnavailable
    case windowUnavailable
    case emptySelection
    case unableToAddRecordingOutput
    case recordingDidNotFinalize
    case alreadyPaused
    case notPaused
    case transitionInProgress

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "已经在录制。"
        case .notRecording: "当前没有正在进行的录制。"
        case .displayUnavailable: "无法找到要录制的显示器。"
        case .windowUnavailable: "所选窗口已经关闭，请重新选择。"
        case .emptySelection: "录屏选区为空。"
        case .unableToAddRecordingOutput: "无法创建系统录制输出。"
        case .recordingDidNotFinalize: "系统未能及时完成录屏文件。"
        case .alreadyPaused: "录制已经暂停。"
        case .notPaused: "录制当前没有暂停。"
        case .transitionInProgress: "录制正在切换状态，请稍候。"
        }
    }
}

struct ScreenRecordingOptions: Sendable {
    var framesPerSecond = 60
    var capturesSystemAudio = true
    var capturesMicrophone = false
    var capturesCamera = false
    var excludesCurrentProcessAudio = true
    var excludesCurrentProcessWindows = true
    var initialEditPlan: AutoEditPlan?
}

struct DiscardedRecording: Sendable {
    let packageURL: URL
    let source: RecordingCaptureSource
}

struct WindowSourceLossDetector: Sendable {
    let requiredConsecutiveMisses: Int
    private(set) var consecutiveMisses = 0

    init(requiredConsecutiveMisses: Int = 2) {
        self.requiredConsecutiveMisses = max(requiredConsecutiveMisses, 1)
    }

    mutating func record(isAvailable: Bool) -> Bool {
        if isAvailable {
            consecutiveMisses = 0
            return false
        }
        consecutiveMisses += 1
        return consecutiveMisses >= requiredConsecutiveMisses
    }
}

private final class ScreenCaptureOutputRouter: NSObject, SCStreamOutput,
    @unchecked Sendable {
    private let videoWriter: ScreenVideoTrackWriter
    private let systemAudioWriter: SystemAudioTrackWriter?
    private let onOnscreenCaptureBounds: @Sendable (CGRect) -> Void
    private let metricsLock = NSLock()
    private var rawAudioCallbackCount = 0

    var audioCallbackCount: Int {
        metricsLock.withLock { rawAudioCallbackCount }
    }

    init(
        videoWriter: ScreenVideoTrackWriter,
        systemAudioWriter: SystemAudioTrackWriter?,
        onOnscreenCaptureBounds: @escaping @Sendable (CGRect) -> Void = { _ in }
    ) {
        self.videoWriter = videoWriter
        self.systemAudioWriter = systemAudioWriter
        self.onOnscreenCaptureBounds = onOnscreenCaptureBounds
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            if let bounds = Self.onscreenCaptureBounds(from: sampleBuffer) {
                onOnscreenCaptureBounds(bounds)
            }
            videoWriter.stream(
                stream,
                didOutputSampleBuffer: sampleBuffer,
                of: type
            )
        case .audio:
            metricsLock.withLock { rawAudioCallbackCount += 1 }
            systemAudioWriter?.stream(
                stream,
                didOutputSampleBuffer: sampleBuffer,
                of: type
            )
        default:
            break
        }
    }

    private static func onscreenCaptureBounds(
        from sampleBuffer: CMSampleBuffer
    ) -> CGRect? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let value = attachments.first?[.screenRect] else { return nil }

        let rect: CGRect?
        if let dictionary = value as? NSDictionary {
            rect = CGRect(dictionaryRepresentation: dictionary)
        } else if let value = value as? NSValue {
            rect = value.rectValue
        } else {
            rect = nil
        }
        guard let rect,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else { return nil }
        return rect.standardized
    }
}

@MainActor
final class ScreenRecordingService: NSObject {
    private let store: LensProjectStore
    private let pointerRecorder: PointerEventRecorder
    private let systemAudioMeter = AudioLevelMeter()
    private let microphoneMeter = AudioLevelMeter()
    private lazy var microphoneRecorder: MicrophoneTrackRecorder = {
        let recorder = MicrophoneTrackRecorder(levelMeter: microphoneMeter)
        recorder.onUnexpectedStop = { [weak self] error in
            self?.recordOptionalTrackInterruption(.microphone, error: error)
        }
        return recorder
    }()
    private lazy var cameraRecorder: CameraTrackRecorder = {
        let recorder = CameraTrackRecorder()
        recorder.onUnexpectedStop = { [weak self] error in
            self?.recordOptionalTrackInterruption(.camera, error: error)
        }
        return recorder
    }()
    private let segmentAssembler = RecordingSegmentAssembler()
    private lazy var artifactValidator = RecordingArtifactValidator(store: store)
    private var stream: SCStream?
    private var recordingWriter: ScreenVideoTrackWriter?
    private var systemAudioWriter: SystemAudioTrackWriter?
    private var captureOutputRouter: ScreenCaptureOutputRouter?
    private var session: RecordingLensSession?
    private var source: RecordingCaptureSource?
    private var options: ScreenRecordingOptions?
    private var outputDimensions: LensDimensions?
    private var currentSegmentPaths: RecordingSegmentPaths?
    private var activeSegmentStartedAtUptime: TimeInterval?
    private var accumulatedActiveDuration: TimeInterval = 0
    private var nextSegmentIndex = 1
    private var isTransitioning = false
    private var windowSourceMonitorTask: Task<Void, Never>?
    private var optionalTrackAvailability = RecordingOptionalTrackAvailability()
    private var pendingOptionalTrackInterruptions: [RecordingOptionalTrack: Error] = [:]

    private var unexpectedCaptureFailure: Error?
    private var streamStoppedUnexpectedly = false
    private(set) var lastMicrophoneError: Error?
    private(set) var lastCameraError: Error?
    private(set) var lastCaptureInterruptionError: Error?
    private(set) var lastCapturePerformanceSnapshot: CapturePerformanceSnapshot?
    private(set) var lastSystemAudioCaptureSnapshot: SystemAudioCaptureSnapshot?
    private(set) var lastRawSystemAudioCallbackCount = 0
    private(set) var lastRecordingHealthReport: RecordingHealthReport?
    private(set) var isPaused = false
    var onUnexpectedCaptureStop: ((Error) -> Void)?
    var onOptionalTrackInterruption: ((RecordingOptionalTrack, Error) -> Void)?

    init(store: LensProjectStore, pointerRecorder: PointerEventRecorder) {
        self.store = store
        self.pointerRecorder = pointerRecorder
    }

    var isRecording: Bool { session != nil }
    var audioLevels: (system: Double, microphone: Double) {
        (systemAudioMeter.level, microphoneMeter.level)
    }
    var eventCaptureSnapshot: EventCaptureSnapshot {
        pointerRecorder.eventCaptureSnapshot
    }
    var usesEmbeddedCursorFallback: Bool {
        pointerRecorder.requiresEmbeddedCursorFallback
    }
    var capturePerformanceSnapshot: CapturePerformanceSnapshot? {
        recordingWriter?.performanceSnapshot ?? lastCapturePerformanceSnapshot
    }

    private var interruptedRawTrackKinds: Set<RecordingRawTrackKind> {
        Set(optionalTrackAvailability.disabledTracks.map {
            switch $0 {
            case .microphone: .microphone
            case .camera: .camera
            }
        })
    }

    private func recordOptionalTrackInterruption(
        _ track: RecordingOptionalTrack,
        error: Error
    ) {
        guard session != nil,
              optionalTrackAvailability.disable(track) else { return }
        switch track {
        case .microphone:
            lastMicrophoneError = lastMicrophoneError ?? error
        case .camera:
            lastCameraError = lastCameraError ?? error
        }
        if isTransitioning {
            pendingOptionalTrackInterruptions[track] = error
        } else {
            onOptionalTrackInterruption?(track, error)
        }
    }

    private func finishTransition() {
        isTransitioning = false
        guard session != nil, !pendingOptionalTrackInterruptions.isEmpty else {
            pendingOptionalTrackInterruptions.removeAll()
            return
        }
        let interruptions = pendingOptionalTrackInterruptions
        pendingOptionalTrackInterruptions.removeAll()
        for track in RecordingOptionalTrack.allCases {
            if let error = interruptions[track] {
                onOptionalTrackInterruption?(track, error)
            }
        }
    }

    func start(
        source: RecordingCaptureSource,
        options: ScreenRecordingOptions = ScreenRecordingOptions()
    ) async throws -> RecordingLensSession {
        guard session == nil else { throw ScreenRecordingError.alreadyRecording }
        guard !isTransitioning else { throw ScreenRecordingError.transitionInProgress }
        isTransitioning = true
        defer { finishTransition() }
        lastMicrophoneError = nil
        lastCameraError = nil
        lastCaptureInterruptionError = nil
        lastCapturePerformanceSnapshot = nil
        lastSystemAudioCaptureSnapshot = nil
        lastRawSystemAudioCallbackCount = 0
        lastRecordingHealthReport = nil
        systemAudioMeter.reset()
        microphoneMeter.reset()
        optionalTrackAvailability = RecordingOptionalTrackAvailability()
        pendingOptionalTrackInterruptions.removeAll()

        let content = try await shareableContent()
        let prepared = try prepare(
            source: source,
            content: content,
            excludesCurrentProcessWindows: options.excludesCurrentProcessWindows
        )
        let session = try store.beginRecording(
            width: prepared.dimensions.width,
            height: prepared.dimensions.height,
            captureSource: LensCaptureMetadata(
                recordingSource: source,
                actualCaptureBounds: prepared.captureBounds,
                actualSourceRect: prepared.sourceRect,
                framesPerSecond: options.framesPerSecond
            ),
            includesSystemAudio: options.capturesSystemAudio,
            includesMicrophone: options.capturesMicrophone,
            includesCamera: options.capturesCamera,
            initialEditPlan: options.initialEditPlan
        )

        self.session = session
        self.source = source
        self.options = options
        outputDimensions = prepared.dimensions
        accumulatedActiveDuration = 0
        nextSegmentIndex = 1
        isPaused = false
        let firstPaths = RecordingSegmentPaths(
            index: 0,
            screenURL: session.videoURL,
            microphoneURL: session.microphoneURL,
            cameraURL: session.cameraURL
        )

        do {
            try await startActiveSegment(
                session: session,
                source: source,
                options: options,
                prepared: prepared,
                paths: firstPaths
            )
            return session
        } catch {
            try? store.markRecordingInterrupted(session)
            clearSession()
            throw error
        }
    }

    func pause() async throws {
        guard let session else { throw ScreenRecordingError.notRecording }
        guard !isPaused else { throw ScreenRecordingError.alreadyPaused }
        guard !isTransitioning else { throw ScreenRecordingError.transitionInProgress }
        isTransitioning = true
        defer { finishTransition() }

        do {
            try await finishActiveSegment(session: session)
            isPaused = true
        } catch {
            isPaused = stream == nil
            throw error
        }
    }

    func resume() async throws {
        guard let session, let source, let options, let outputDimensions else {
            throw ScreenRecordingError.notRecording
        }
        guard isPaused else { throw ScreenRecordingError.notPaused }
        guard !isTransitioning else { throw ScreenRecordingError.transitionInProgress }
        isTransitioning = true
        defer { finishTransition() }

        let content = try await shareableContent()
        let prepared = try prepare(
            source: source,
            content: content,
            excludesCurrentProcessWindows: options.excludesCurrentProcessWindows
        )
        let segmentIndex = nextSegmentIndex
        nextSegmentIndex += 1
        let paths = try makeResumedSegmentPaths(
            index: segmentIndex,
            session: session,
            options: options
        )
        let segment = RecordingSegment(
            index: segmentIndex,
            timelineStartSeconds: accumulatedActiveDuration,
            screenRelativePath: relativePath(paths.screenURL, in: session.packageURL),
            microphoneRelativePath: paths.microphoneURL.map {
                relativePath($0, in: session.packageURL)
            },
            cameraRelativePath: paths.cameraURL.map {
                relativePath($0, in: session.packageURL)
            }
        )
        try store.appendRecordingSegment(segment, to: session)

        do {
            try await startActiveSegment(
                session: session,
                source: source,
                options: options,
                prepared: prepared,
                paths: paths,
                dimensions: outputDimensions
            )
            isPaused = false
        } catch {
            if !paths.containsNonemptyFile {
                try? store.discardRecordingSegment(index: segmentIndex, from: session)
            }
            throw error
        }
    }

    func stop() async throws -> SavedLens {
        guard let session else { throw ScreenRecordingError.notRecording }
        guard !isTransitioning else { throw ScreenRecordingError.transitionInProgress }
        isTransitioning = true
        defer { finishTransition() }

        do {
            if stream != nil {
                try await finishActiveSegment(session: session)
            }
            let segmentIndex = try store.loadRecordingSegmentIndex(from: session.packageURL)
            var completedSegments = try await finalizableSegments(
                from: segmentIndex,
                session: session
            )
            guard !completedSegments.isEmpty else {
                throw ScreenRecordingError.recordingDidNotFinalize
            }
            completedSegments = try await archiveFirstSegmentsIfNeeded(
                completedSegments,
                session: session
            )
            try await assembleScreenSegments(completedSegments, session: session)
            await assembleOptionalTracks(completedSegments, session: session)
            let duration = completedSegments.reduce(0) {
                $0 + ($1.durationSeconds ?? 0)
            }
            // 自动处理失败绝不能让已经完成的原始录屏变成失败状态。
            _ = try? store.writeAutoEditPlan(for: session, durationSeconds: duration)
            let saved = try store.finalizeRecording(session, durationSeconds: duration)
            let report = await artifactValidator.validate(
                session: session,
                requestedFramesPerSecond: options?.framesPerSecond
                    ?? session.manifest.captureSource?.requestedFramesPerSecond
                    ?? session.manifest.captureSource?.framesPerSecond
                    ?? 30,
                eventSnapshot: pointerRecorder.eventCaptureSnapshot,
                capturePerformance: lastCapturePerformanceSnapshot,
                interruptedOptionalTracks: interruptedRawTrackKinds
            )
            lastRecordingHealthReport = report
            let validated = (try? store.writeRecordingHealthReport(
                report,
                to: session.packageURL
            )) ?? saved
            clearSession()
            return validated
        } catch {
            await pointerRecorder.stop()
            await cameraRecorder.cancel()
            microphoneRecorder.cancel()
            try? store.markRecordingInterrupted(session)
            clearSession()
            throw error
        }
    }

    /// Stops every active writer without finalizing a playable project. The package remains on
    /// disk as an interrupted, recoverable capture until the caller successfully moves it to Trash.
    func stopForDiscard() async throws -> DiscardedRecording {
        guard let session, let source else { throw ScreenRecordingError.notRecording }
        guard !isTransitioning else { throw ScreenRecordingError.transitionInProgress }
        isTransitioning = true
        defer { finishTransition() }

        do {
            if stream != nil {
                try await finishActiveSegment(session: session)
            } else {
                await pointerRecorder.stop()
                await cameraRecorder.cancel()
                microphoneRecorder.cancel()
            }
            try store.markRecordingInterrupted(session)
            let discarded = DiscardedRecording(packageURL: session.packageURL, source: source)
            clearSession()
            return discarded
        } catch {
            await pointerRecorder.stop()
            await cameraRecorder.cancel()
            microphoneRecorder.cancel()
            try? store.markRecordingInterrupted(session)
            clearSession()
            throw error
        }
    }

    /// Turns media left behind by an unclean process exit into the same processable project
    /// produced by a normal stop. Every screen segment is validated before the manifest is
    /// advanced, so an unreadable partial file remains visibly interrupted instead of being
    /// presented as a completed recording.
    func recoverInterruptedRecording(
        _ candidate: RecordingRecoveryCandidate
    ) async throws -> SavedLens {
        let manifest = try store.loadManifest(from: candidate.packageURL)
        let session = recoverySession(
            packageURL: candidate.packageURL,
            videoURL: candidate.videoURL,
            manifest: manifest
        )
        let index = try store.loadRecordingSegmentIndex(from: candidate.packageURL)
        var completedSegments: [RecordingSegment] = []
        var hasNonemptyScreenSegment = false
        for var segment in index.segments.sorted(by: { $0.index < $1.index }) {
            let segmentURL = candidate.packageURL.appendingPathComponent(
                segment.screenRelativePath
            )
            hasNonemptyScreenSegment = hasNonemptyScreenSegment
                || segmentURL.isNonemptyFile
            // A SIGKILL can leave independently durable Apple HLS video and
            // system-audio sequences. Recover the ordinary muxed MP4 before
            // deciding whether this segment is playable.
            // If durable system-audio fragments exist but cannot be remuxed,
            // keep the project interrupted so recovery can be retried. A
            // video-only "success" would silently discard recoverable audio.
            _ = try await segmentAssembler.mergeRecoverySystemAudioIfPresent(
                videoURL: segmentURL,
                trimVideoToRecoveredAudio: true
            )
            guard let duration = try? await playableVideoDuration(at: segmentURL),
                  duration >= VideoEditTimeline.minimumSegmentDurationSeconds else {
                continue
            }
            segment.durationSeconds = duration
            _ = try store.completeRecordingSegment(
                index: segment.index,
                durationSeconds: duration,
                in: session
            )
            completedSegments.append(segment)
        }
        guard !completedSegments.isEmpty else {
            if !hasNonemptyScreenSegment {
                // Missing/zero-byte screen media cannot become recoverable on a
                // later launch. Preserve the package but quarantine it from the
                // retry queue; nonempty yet currently unreadable media remains
                // interrupted so a future app update can try again.
                try? store.markRecordingRecoveryFailed(
                    packageURL: candidate.packageURL
                )
            }
            throw ScreenRecordingError.recordingDidNotFinalize
        }

        completedSegments = try await archiveFirstSegmentsIfNeeded(
            completedSegments,
            session: session
        )
        try await assembleScreenSegments(completedSegments, session: session)
        await assembleOptionalTracks(completedSegments, session: session)
        let duration = completedSegments.reduce(0) {
            $0 + ($1.durationSeconds ?? 0)
        }
        _ = try? store.writeAutoEditPlan(for: session, durationSeconds: duration)
        let saved = try store.finalizeRecording(session, durationSeconds: duration)
        let report = await artifactValidator.validate(
            session: session,
            requestedFramesPerSecond: manifest.captureSource?.requestedFramesPerSecond
                ?? manifest.captureSource?.framesPerSecond
                ?? 30,
            eventSnapshot: EventCaptureSnapshot(
                health: .checking,
                pointerCount: 0,
                clickCount: 0,
                keyboardCount: 0,
                windowCount: 0,
                lastEventUptime: nil
            ),
            capturePerformance: nil
        )
        return (try? store.writeRecordingHealthReport(
            report,
            to: session.packageURL
        )) ?? saved
    }

    private func startActiveSegment(
        session: RecordingLensSession,
        source: RecordingCaptureSource,
        options: ScreenRecordingOptions,
        prepared: PreparedRecordingSource,
        paths: RecordingSegmentPaths,
        dimensions: LensDimensions? = nil
    ) async throws {
        let dimensions = dimensions ?? prepared.dimensions
        var pendingWriter: ScreenVideoTrackWriter?
        var pendingSystemAudioWriter: SystemAudioTrackWriter?
        do {
            try pointerRecorder.start(
                session: session,
                captureBounds: prepared.captureBounds,
                trackedWindowID: prepared.trackedWindowID,
                timelineOffset: accumulatedActiveDuration
            )
            let pipeline = try makeCapturePipeline(
                source: source,
                options: options,
                prepared: prepared,
                dimensions: dimensions,
                outputURL: paths.screenURL,
                embedsCursorFallback: pointerRecorder.requiresEmbeddedCursorFallback
            )
            pendingWriter = pipeline.writer
            pendingSystemAudioWriter = pipeline.systemAudioWriter
            if let microphoneURL = paths.microphoneURL {
                do {
                    try microphoneRecorder.start(outputURL: microphoneURL)
                } catch {
                    recordOptionalTrackInterruption(.microphone, error: error)
                    removeFailedOptionalTrackStart(
                        role: .microphone,
                        paths: paths,
                        session: session
                    )
                }
            }
            if let cameraURL = paths.cameraURL {
                do {
                    try await cameraRecorder.start(outputURL: cameraURL)
                } catch {
                    recordOptionalTrackInterruption(.camera, error: error)
                    removeFailedOptionalTrackStart(
                        role: .camera,
                        paths: paths,
                        session: session
                    )
                }
            }
            try await startCapture(pipeline.stream)
            stream = pipeline.stream
            recordingWriter = pipeline.writer
            systemAudioWriter = pipeline.systemAudioWriter
            captureOutputRouter = pipeline.outputRouter
            currentSegmentPaths = paths
            activeSegmentStartedAtUptime = ProcessInfo.processInfo.systemUptime
            startWindowSourceMonitoring(
                windowID: prepared.trackedWindowID,
                stream: pipeline.stream
            )
        } catch {
            pendingWriter?.cancel()
            pendingSystemAudioWriter?.cancel()
            await cameraRecorder.cancel()
            microphoneRecorder.cancel()
            await pointerRecorder.stop()
            removeEmptyOptionalTracks(paths: paths, session: session)
            throw error
        }
    }

    private func recoverySession(
        packageURL: URL,
        videoURL: URL,
        manifest: LensManifest
    ) -> RecordingLensSession {
        func assetURL(for role: LensAsset.Role) -> URL? {
            manifest.assets.first(where: { $0.role == role }).map {
                packageURL.appendingPathComponent($0.relativePath)
            }
        }
        return RecordingLensSession(
            packageURL: packageURL,
            videoURL: videoURL,
            pointerEventsURL: assetURL(for: .pointerEvents)
                ?? packageURL.appendingPathComponent("events/pointer.jsonl"),
            clickEventsURL: assetURL(for: .clickEvents)
                ?? packageURL.appendingPathComponent("events/clicks.jsonl"),
            keyboardEventsURL: assetURL(for: .keyboardEvents)
                ?? packageURL.appendingPathComponent("events/keyboard.jsonl"),
            windowEventsURL: assetURL(for: .windowEvents)
                ?? packageURL.appendingPathComponent("events/windows.jsonl"),
            segmentIndexURL: assetURL(for: .recordingSegments)
                ?? packageURL.appendingPathComponent("events/segments.json"),
            editPlanURL: assetURL(for: .editPlan)
                ?? packageURL.appendingPathComponent("edits/edit-plan.json"),
            microphoneURL: assetURL(for: .microphone),
            cameraURL: assetURL(for: .camera),
            manifest: manifest
        )
    }

    private func playableVideoDuration(at url: URL) async throws -> Double {
        guard url.isNonemptyFile else {
            throw LensProjectStoreError.emptyRawRecording
        }
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecordingSegmentAssemblerError.missingVideoTrack(url.lastPathComponent)
        }
        let timeRange = try await videoTrack.load(.timeRange)
        let seconds = timeRange.duration.seconds
        guard timeRange.duration.isNumeric, seconds.isFinite, seconds > 0 else {
            throw RecordingSegmentAssemblerError.missingVideoTrack(url.lastPathComponent)
        }
        return seconds
    }

    /// Recovers playable media that reached disk before a capture callback or
    /// pause transition failed to persist the segment duration. Such a segment
    /// must not be silently omitted from an otherwise successful finalization.
    func finalizableSegments(
        from index: RecordingSegmentIndex,
        session: RecordingLensSession
    ) async throws -> [RecordingSegment] {
        var result: [RecordingSegment] = []
        for var segment in index.segments.sorted(by: { $0.index < $1.index }) {
            let mediaURL = session.packageURL.appendingPathComponent(
                segment.screenRelativePath
            )
            guard let duration = try? await playableVideoDuration(at: mediaURL),
                  duration >= VideoEditTimeline.minimumSegmentDurationSeconds else {
                continue
            }
            if segment.durationSeconds == nil
                || abs((segment.durationSeconds ?? 0) - duration) > 0.01 {
                _ = try store.completeRecordingSegment(
                    index: segment.index,
                    durationSeconds: duration,
                    in: session
                )
            }
            segment.durationSeconds = duration
            result.append(segment)
        }
        return result
    }

    private func finishActiveSegment(session: RecordingLensSession) async throws {
        guard let stream, let paths = currentSegmentPaths else {
            throw ScreenRecordingError.notRecording
        }
        stopWindowSourceMonitoring()
        let measuredDuration = max(
            0,
            ProcessInfo.processInfo.systemUptime - (activeSegmentStartedAtUptime ?? 0)
        )
        do {
            try microphoneRecorder.stop()
        } catch {
            recordOptionalTrackInterruption(.microphone, error: error)
            removeEmptyOptionalTrack(role: .microphone, paths: paths, session: session)
        }
        let cameraRecorder = cameraRecorder
        let cameraStopTask = Task { @MainActor () -> Error? in
            do {
                try await cameraRecorder.stop()
                return nil
            } catch {
                return error
            }
        }

        do {
            try await stopCapture(stream)
            await pointerRecorder.stop()
            if let cameraError = await cameraStopTask.value {
                recordOptionalTrackInterruption(.camera, error: cameraError)
                removeEmptyOptionalTrack(role: .camera, paths: paths, session: session)
            }
            try validateNonemptyFile(at: paths.screenURL)
            let mediaDuration = try await AVURLAsset(url: paths.screenURL).load(.duration).seconds
            let duration = mediaDuration.isFinite && mediaDuration > 0
                ? mediaDuration
                : measuredDuration
            _ = try store.completeRecordingSegment(
                index: paths.index,
                durationSeconds: duration,
                in: session
            )
            accumulatedActiveDuration += duration
            systemAudioMeter.reset()
            microphoneMeter.reset()
            clearActiveSegment()
        } catch {
            await pointerRecorder.stop()
            if let cameraError = await cameraStopTask.value {
                recordOptionalTrackInterruption(.camera, error: cameraError)
                removeEmptyOptionalTrack(role: .camera, paths: paths, session: session)
            }
            clearActiveSegment()
            throw error
        }
    }

    private func stopCapture(_ stream: SCStream) async throws {
        var captureInterruption = unexpectedCaptureFailure
        recordingWriter?.prepareToFinish()
        systemAudioWriter?.prepareToFinish()
        if !streamStoppedUnexpectedly {
            do {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    stream.stopCapture { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } catch {
                captureInterruption = captureInterruption ?? error
            }
        }
        if let recordingWriter {
            do {
                try await recordingWriter.finish()
                lastCapturePerformanceSnapshot = recordingWriter.performanceSnapshot
            } catch {
                // A writer failure means there is no trustworthy playable
                // screen segment. A ScreenCaptureKit stop error is different:
                // if the writer finalized, preserve and finalize those bytes
                // instead of forcing the user to relaunch for recovery.
                throw error
            }
        }
        if let systemAudioWriter {
            do {
                try await systemAudioWriter.finish()
            } catch SystemAudioTrackWriterError.noSamples {
                // A session whose audio output delivers no samples (for
                // example no output device is present) still has an intact
                // screen track. Degrade to a missing system-audio track — the
                // requested-track integrity warning already reports that —
                // instead of failing the whole stop and forcing recovery.
            }
            lastSystemAudioCaptureSnapshot = systemAudioWriter.captureSnapshot
        }
        lastRawSystemAudioCallbackCount = captureOutputRouter?.audioCallbackCount ?? 0
        if let screenURL = currentSegmentPaths?.screenURL {
            _ = try await segmentAssembler
                .mergeRecoverySystemAudioIfPresent(videoURL: screenURL)
        }
        if let captureInterruption {
            lastCaptureInterruptionError = captureInterruption
        }
    }

    private func makeCapturePipeline(
        source: RecordingCaptureSource,
        options: ScreenRecordingOptions,
        prepared: PreparedRecordingSource,
        dimensions: LensDimensions,
        outputURL: URL,
        embedsCursorFallback: Bool
    ) throws -> (
        stream: SCStream,
        writer: ScreenVideoTrackWriter,
        systemAudioWriter: SystemAudioTrackWriter?,
        outputRouter: ScreenCaptureOutputRouter
    ) {
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(options.framesPerSecond, 1))
        )
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = embedsCursorFallback
        configuration.showMouseClicks = embedsCursorFallback
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = options.excludesCurrentProcessAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = false
        configuration.captureResolution = .best
        configuration.preservesAspectRatio = true
        if let sourceRect = prepared.sourceRect {
            configuration.sourceRect = sourceRect
        }
        if source.mode == .window {
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.scalesToFit = true
        }
        let stream = SCStream(
            filter: prepared.filter,
            configuration: configuration,
            delegate: self
        )
        let writer = try ScreenVideoTrackWriter(
            outputURL: outputURL,
            dimensions: dimensions,
            framesPerSecond: options.framesPerSecond,
            capturesSystemAudio: false
        )
        let systemAudioWriter = try options.capturesSystemAudio
            ? SystemAudioTrackWriter(
                outputURL: ScreenVideoTrackWriter.recoverySystemAudioURL(
                    for: outputURL
                ),
                levelMeter: systemAudioMeter
            )
            : nil
        let outputRouter = ScreenCaptureOutputRouter(
            videoWriter: writer,
            systemAudioWriter: systemAudioWriter,
            onOnscreenCaptureBounds: { [weak pointerRecorder] bounds in
                DispatchQueue.main.async { @MainActor in
                    pointerRecorder?.updateOnscreenCaptureBounds(bounds)
                }
            }
        )
        do {
            try stream.addStreamOutput(
                outputRouter,
                type: .screen,
                sampleHandlerQueue: writer.outputQueue
            )
            if options.capturesSystemAudio {
                guard systemAudioWriter != nil else {
                    throw ScreenRecordingError.unableToAddRecordingOutput
                }
                try stream.addStreamOutput(
                    outputRouter,
                    type: .audio,
                    // ScreenCaptureKit's screen and audio callbacks share one
                    // serial delivery boundary. The audio writer immediately
                    // forwards onto its own encoder queue; using two delivery
                    // queues caused audio callbacks to stop after ~1.25 s on
                    // real macOS while screen frames continued normally.
                    sampleHandlerQueue: writer.outputQueue
                )
            }
        } catch {
            writer.cancel()
            systemAudioWriter?.cancel()
            throw error
        }
        return (stream, writer, systemAudioWriter, outputRouter)
    }

    private func makeResumedSegmentPaths(
        index: Int,
        session: RecordingLensSession,
        options: ScreenRecordingOptions
    ) throws -> RecordingSegmentPaths {
        let directory = session.packageURL.appendingPathComponent("raw/segments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = String(format: "%03d", index)
        return RecordingSegmentPaths(
            index: index,
            screenURL: directory.appendingPathComponent("screen-\(suffix).mp4"),
            microphoneURL: optionalTrackAvailability.isEnabled(
                .microphone,
                requestedOptions: options
            )
                ? directory.appendingPathComponent("microphone-\(suffix).caf")
                : nil,
            cameraURL: optionalTrackAvailability.isEnabled(
                .camera,
                requestedOptions: options
            )
                ? directory.appendingPathComponent("camera-\(suffix).mov")
                : nil
        )
    }

    private func assembleScreenSegments(
        _ segments: [RecordingSegment],
        session: RecordingLensSession
    ) async throws {
        let urls = segments.map {
            session.packageURL.appendingPathComponent($0.screenRelativePath)
        }
        _ = try await segmentAssembler.assembleVideoSegments(
            urls,
            outputURL: session.videoURL,
            fileType: .mp4
        )
    }

    func archiveFirstSegmentsIfNeeded(
        _ segments: [RecordingSegment],
        session: RecordingLensSession
    ) async throws -> [RecordingSegment] {
        guard segments.count > 1,
              let firstPosition = segments.firstIndex(where: { $0.index == 0 }) else {
            return segments
        }
        let directory = session.packageURL.appendingPathComponent("raw/segments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archived = segments[firstPosition]
        let archivedScreenURL = directory.appendingPathComponent("screen-000.mp4")
        try await segmentAssembler.copyFileIfNeeded(session.videoURL, to: archivedScreenURL)
        let microphoneRelativePath: String?
        if archived.microphoneRelativePath != nil,
           let microphoneURL = session.microphoneURL,
           microphoneURL.isNonemptyFile {
            let destination = directory.appendingPathComponent("microphone-000.caf")
            try await segmentAssembler.copyFileIfNeeded(microphoneURL, to: destination)
            microphoneRelativePath = relativePath(destination, in: session.packageURL)
        } else {
            microphoneRelativePath = nil
        }
        let cameraRelativePath: String?
        if archived.cameraRelativePath != nil,
           let cameraURL = session.cameraURL,
           cameraURL.isNonemptyFile {
            let destination = directory.appendingPathComponent("camera-000.mov")
            try await segmentAssembler.copyFileIfNeeded(cameraURL, to: destination)
            cameraRelativePath = relativePath(destination, in: session.packageURL)
        } else {
            cameraRelativePath = nil
        }
        let archivedSegment = RecordingSegment(
            index: archived.index,
            timelineStartSeconds: archived.timelineStartSeconds,
            durationSeconds: archived.durationSeconds,
            screenRelativePath: relativePath(archivedScreenURL, in: session.packageURL),
            microphoneRelativePath: microphoneRelativePath,
            cameraRelativePath: cameraRelativePath
        )
        try store.appendRecordingSegment(archivedSegment, to: session)
        var result = segments
        result[firstPosition] = archivedSegment
        return result
    }

    private func assembleOptionalTracks(
        _ segments: [RecordingSegment],
        session: RecordingLensSession
    ) async {
        if let microphoneURL = session.microphoneURL {
            let sources = segments.compactMap { segment -> (URL, Double)? in
                guard let relativePath = segment.microphoneRelativePath,
                      let duration = segment.durationSeconds else { return nil }
                let url = session.packageURL.appendingPathComponent(relativePath)
                return url.isNonemptyFile ? (url, duration) : nil
            }
            let urls = sources.map(\.0)
            if !urls.isEmpty {
                do {
                    _ = try await segmentAssembler.assembleAudioSegments(
                        urls,
                        outputURL: microphoneURL,
                        maximumDurations: sources.map(\.1)
                    )
                    try store.upsertAsset(
                        LensAsset(role: .microphone, relativePath: "raw/microphone.caf"),
                        in: session.packageURL
                    )
                } catch {
                    lastMicrophoneError = lastMicrophoneError ?? error
                }
            }
        }
        if let cameraURL = session.cameraURL {
            let sources = segments.compactMap { segment -> (URL, Double)? in
                guard let relativePath = segment.cameraRelativePath,
                      let duration = segment.durationSeconds else { return nil }
                let url = session.packageURL.appendingPathComponent(relativePath)
                return url.isNonemptyFile ? (url, duration) : nil
            }
            let urls = sources.map(\.0)
            if !urls.isEmpty {
                do {
                    _ = try await segmentAssembler.assembleVideoSegments(
                        urls,
                        outputURL: cameraURL,
                        fileType: .mov,
                        maximumDurations: sources.map(\.1)
                    )
                    try store.upsertAsset(
                        LensAsset(role: .camera, relativePath: "raw/camera.mov"),
                        in: session.packageURL
                    )
                } catch {
                    lastCameraError = lastCameraError ?? error
                }
            }
        }
    }

    private func clearActiveSegment() {
        stopWindowSourceMonitoring()
        stream = nil
        recordingWriter = nil
        systemAudioWriter = nil
        captureOutputRouter = nil
        currentSegmentPaths = nil
        activeSegmentStartedAtUptime = nil
        unexpectedCaptureFailure = nil
        streamStoppedUnexpectedly = false
    }

    private func clearSession() {
        clearActiveSegment()
        session = nil
        source = nil
        options = nil
        outputDimensions = nil
        accumulatedActiveDuration = 0
        nextSegmentIndex = 1
        isPaused = false
        optionalTrackAvailability = RecordingOptionalTrackAvailability()
        pendingOptionalTrackInterruptions.removeAll()
        systemAudioMeter.reset()
        microphoneMeter.reset()
    }

    private func removeEmptyOptionalTracks(
        paths: RecordingSegmentPaths,
        session: RecordingLensSession
    ) {
        removeEmptyOptionalTrack(role: .microphone, paths: paths, session: session)
        removeEmptyOptionalTrack(role: .camera, paths: paths, session: session)
    }

    private func removeEmptyOptionalTrack(
        role: LensAsset.Role,
        paths: RecordingSegmentPaths,
        session: RecordingLensSession
    ) {
        let url = role == .microphone ? paths.microphoneURL : paths.cameraURL
        guard let url, !url.isNonemptyFile else { return }
        try? store.removeRecordingSegmentMedia(
            role: role,
            segmentIndex: paths.index,
            from: session
        )
    }

    /// A recorder can create a nonempty but unusable container before its
    /// startup throws. Never advertise that file as a valid segment. The exact
    /// generated file is left in place for diagnostics/recovery, but it is
    /// removed from the segment index and manifest used for final assembly.
    private func removeFailedOptionalTrackStart(
        role: LensAsset.Role,
        paths: RecordingSegmentPaths,
        session: RecordingLensSession
    ) {
        try? store.removeRecordingSegmentMedia(
            role: role,
            segmentIndex: paths.index,
            from: session
        )
    }

    private func validateNonemptyFile(at url: URL) throws {
        guard url.isNonemptyFile else { throw LensProjectStoreError.emptyRawRecording }
    }

    private func relativePath(_ url: URL, in packageURL: URL) -> String {
        url.path.replacingOccurrences(of: packageURL.path + "/", with: "")
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: ScreenRecordingError.displayUnavailable)
                }
            }
        }
    }

    private func startWindowSourceMonitoring(
        windowID: CGWindowID?,
        stream: SCStream
    ) {
        stopWindowSourceMonitoring()
        guard let windowID else { return }
        windowSourceMonitorTask = Task { @MainActor [weak self, weak stream] in
            var detector = WindowSourceLossDetector()
            while !Task.isCancelled {
                // A 1.5-second cadence keeps this one-window server lookup
                // negligible while still detecting a close in roughly three
                // seconds after two independent misses.
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled,
                      let self,
                      let stream,
                      self.stream === stream else { return }
                let content: SCShareableContent
                do {
                    content = try await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: false
                    )
                } catch {
                    // A source-enumeration failure is not evidence that the
                    // user's window disappeared. Stream errors remain covered
                    // independently by SCStreamDelegate.
                    continue
                }
                let isAvailable = content.windows.contains {
                    $0.windowID == windowID
                }
                guard detector.record(isAvailable: isAvailable) else { continue }
                let error = ScreenRecordingError.windowUnavailable
                self.windowSourceMonitorTask = nil
                self.unexpectedCaptureFailure = self.unexpectedCaptureFailure ?? error
                await self.pointerRecorder.stop()
                if !self.isTransitioning {
                    self.onUnexpectedCaptureStop?(error)
                }
                return
            }
        }
    }

    private func stopWindowSourceMonitoring() {
        windowSourceMonitorTask?.cancel()
        windowSourceMonitorTask = nil
    }

    private func prepare(
        source: RecordingCaptureSource,
        content: SCShareableContent,
        excludesCurrentProcessWindows: Bool
    ) throws -> PreparedRecordingSource {
        switch source.mode {
        case .display, .region:
            guard let displayID = source.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingError.displayUnavailable
            }
            let ownWindows = excludesCurrentProcessWindows
                ? content.windows.filter {
                    $0.owningApplication?.bundleIdentifier
                        == Bundle.main.bundleIdentifier
                }
                : []
            let filter = SCContentFilter(
                display: display,
                excludingWindows: ownWindows
            )
            let pointSize: CGSize
            let sourceRect: CGRect?
            let captureBounds: CGRect
            if source.mode == .region {
                guard let requested = source.sourceRect else {
                    throw ScreenRecordingError.emptySelection
                }
                let localDisplayBounds = CGRect(
                    origin: .zero,
                    size: CGSize(width: display.width, height: display.height)
                )
                let clipped = requested.standardized.intersection(localDisplayBounds)
                guard !clipped.isNull, clipped.width >= 3, clipped.height >= 3 else {
                    throw ScreenRecordingError.emptySelection
                }
                pointSize = clipped.size
                sourceRect = clipped
                captureBounds = CaptureGeometry.globalRect(
                    fromLocalRect: clipped,
                    displayBounds: CGDisplayBounds(displayID)
                )
            } else {
                pointSize = CGSize(width: display.width, height: display.height)
                sourceRect = nil
                captureBounds = CGDisplayBounds(displayID)
            }
            return PreparedRecordingSource(
                filter: filter,
                dimensions: CaptureGeometry.recordingPixelDimensions(
                    pointSize: pointSize,
                    pointPixelScale: CGFloat(filter.pointPixelScale)
                ),
                sourceRect: sourceRect,
                captureBounds: captureBounds,
                trackedWindowID: nil
            )

        case .window:
            guard let windowID = source.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenRecordingError.windowUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let pointSize = filter.contentRect.size
            guard pointSize.width >= 3, pointSize.height >= 3 else {
                throw ScreenRecordingError.emptySelection
            }
            return PreparedRecordingSource(
                filter: filter,
                dimensions: CaptureGeometry.recordingPixelDimensions(
                    pointSize: pointSize,
                    pointPixelScale: CGFloat(filter.pointPixelScale)
                ),
                sourceRect: nil,
                captureBounds: window.frame,
                trackedWindowID: window.windowID
            )
        }
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private struct RecordingSegmentPaths {
    let index: Int
    let screenURL: URL
    let microphoneURL: URL?
    let cameraURL: URL?

    var containsNonemptyFile: Bool {
        [screenURL, microphoneURL, cameraURL]
            .compactMap { $0 }
            .contains(where: \.isNonemptyFile)
    }
}

private extension URL {
    var isNonemptyFile: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]
            as? NSNumber)?.int64Value ?? 0
        return size > 0
    }
}

private struct PreparedRecordingSource {
    let filter: SCContentFilter
    let dimensions: LensDimensions
    let sourceRect: CGRect?
    let captureBounds: CGRect
    let trackedWindowID: CGWindowID?
}

extension ScreenRecordingService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            stopWindowSourceMonitoring()
            let shouldNotify = !isTransitioning
            streamStoppedUnexpectedly = true
            unexpectedCaptureFailure = error
            await pointerRecorder.stop()
            if shouldNotify {
                onUnexpectedCaptureStop?(error)
            }
        }
    }
}
