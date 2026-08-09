import AppKit
import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import ScreenTraceCore

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
}

@MainActor
final class ScreenRecordingService: NSObject {
    private let store: TraceProjectStore
    private let pointerRecorder: PointerEventRecorder
    private let systemAudioMeter = AudioLevelMeter()
    private let microphoneMeter = AudioLevelMeter()
    private lazy var systemAudioMonitor = SystemAudioLevelMonitor(meter: systemAudioMeter)
    private lazy var microphoneRecorder = MicrophoneTrackRecorder(levelMeter: microphoneMeter)
    private let cameraRecorder = CameraTrackRecorder()
    private let segmentAssembler = RecordingSegmentAssembler()
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var session: RecordingTraceSession?
    private var source: RecordingCaptureSource?
    private var options: ScreenRecordingOptions?
    private var outputDimensions: TraceDimensions?
    private var currentSegmentPaths: RecordingSegmentPaths?
    private var activeSegmentStartedAtUptime: TimeInterval?
    private var accumulatedActiveDuration: TimeInterval = 0
    private var nextSegmentIndex = 1
    private var isTransitioning = false

    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var stopCaptureCompleted = false
    private var recordingOutputFinished = false
    private var stopFailure: Error?
    private var stopGeneration = 0
    private var unexpectedCaptureFailure: Error?
    private var streamStoppedUnexpectedly = false
    private var outputFinishedUnexpectedly = false
    private(set) var lastMicrophoneError: Error?
    private(set) var lastCameraError: Error?
    private(set) var isPaused = false

    init(store: TraceProjectStore, pointerRecorder: PointerEventRecorder) {
        self.store = store
        self.pointerRecorder = pointerRecorder
    }

    var isRecording: Bool { session != nil }
    var audioLevels: (system: Double, microphone: Double) {
        (systemAudioMeter.level, microphoneMeter.level)
    }

    func start(
        source: RecordingCaptureSource,
        options: ScreenRecordingOptions = ScreenRecordingOptions()
    ) async throws -> RecordingTraceSession {
        guard session == nil else { throw ScreenRecordingError.alreadyRecording }
        guard !isTransitioning else { throw ScreenRecordingError.transitionInProgress }
        isTransitioning = true
        defer { isTransitioning = false }
        lastMicrophoneError = nil
        lastCameraError = nil
        systemAudioMeter.reset()
        microphoneMeter.reset()

        let content = try await shareableContent()
        let prepared = try prepare(source: source, content: content)
        let session = try store.beginRecording(
            width: prepared.dimensions.width,
            height: prepared.dimensions.height,
            captureSource: TraceCaptureMetadata(
                recordingSource: source,
                actualCaptureBounds: prepared.captureBounds,
                actualSourceRect: prepared.sourceRect
            ),
            includesSystemAudio: options.capturesSystemAudio,
            includesMicrophone: options.capturesMicrophone,
            includesCamera: options.capturesCamera
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
        defer { isTransitioning = false }

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
        defer { isTransitioning = false }

        let content = try await shareableContent()
        let prepared = try prepare(source: source, content: content)
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

    func stop() async throws -> SavedTrace {
        guard let session else { throw ScreenRecordingError.notRecording }
        guard !isTransitioning else { throw ScreenRecordingError.transitionInProgress }
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            if stream != nil {
                try await finishActiveSegment(session: session)
            }
            let segmentIndex = try store.loadRecordingSegmentIndex(from: session.packageURL)
            var completedSegments = segmentIndex.segments.filter {
                ($0.durationSeconds ?? 0) > 0
            }
            completedSegments = try archiveFirstSegmentsIfNeeded(
                completedSegments,
                session: session
            )
            try await assembleScreenSegments(completedSegments, session: session)
            await assembleOptionalTracks(completedSegments, session: session)
            let duration = segmentIndex.completedDurationSeconds
            // 自动处理失败绝不能让已经完成的原始录屏变成失败状态。
            _ = try? store.writeAutoEditPlan(for: session, durationSeconds: duration)
            let saved = try store.finalizeRecording(session, durationSeconds: duration)
            clearSession()
            return saved
        } catch {
            await pointerRecorder.stop()
            await cameraRecorder.cancel()
            microphoneRecorder.cancel()
            try? store.markRecordingInterrupted(session)
            clearSession()
            throw error
        }
    }

    private func startActiveSegment(
        session: RecordingTraceSession,
        source: RecordingCaptureSource,
        options: ScreenRecordingOptions,
        prepared: PreparedRecordingSource,
        paths: RecordingSegmentPaths,
        dimensions: TraceDimensions? = nil
    ) async throws {
        let dimensions = dimensions ?? prepared.dimensions
        let pipeline = try makeCapturePipeline(
            source: source,
            options: options,
            prepared: prepared,
            dimensions: dimensions,
            outputURL: paths.screenURL
        )
        do {
            if let microphoneURL = paths.microphoneURL {
                try microphoneRecorder.start(outputURL: microphoneURL)
            }
            if let cameraURL = paths.cameraURL {
                try await cameraRecorder.start(outputURL: cameraURL)
            }
            try pointerRecorder.start(
                session: session,
                captureBounds: prepared.captureBounds,
                trackedWindowID: prepared.trackedWindowID,
                timelineOffset: accumulatedActiveDuration
            )
            try await startCapture(pipeline.stream)
            stream = pipeline.stream
            recordingOutput = pipeline.output
            currentSegmentPaths = paths
            activeSegmentStartedAtUptime = ProcessInfo.processInfo.systemUptime
        } catch {
            await cameraRecorder.cancel()
            microphoneRecorder.cancel()
            await pointerRecorder.stop()
            removeEmptyOptionalTracks(paths: paths, session: session)
            throw error
        }
    }

    private func finishActiveSegment(session: RecordingTraceSession) async throws {
        guard let stream, let paths = currentSegmentPaths else {
            throw ScreenRecordingError.notRecording
        }
        let measuredDuration = max(
            0,
            ProcessInfo.processInfo.systemUptime - (activeSegmentStartedAtUptime ?? 0)
        )
        do {
            try microphoneRecorder.stop()
        } catch {
            lastMicrophoneError = lastMicrophoneError ?? error
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
                lastCameraError = lastCameraError ?? cameraError
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
                lastCameraError = lastCameraError ?? cameraError
                removeEmptyOptionalTrack(role: .camera, paths: paths, session: session)
            }
            clearActiveSegment()
            throw error
        }
    }

    private func stopCapture(_ stream: SCStream) async throws {
        stopGeneration += 1
        let generation = stopGeneration
        stopCaptureCompleted = streamStoppedUnexpectedly
        recordingOutputFinished = outputFinishedUnexpectedly
        stopFailure = unexpectedCaptureFailure
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stopContinuation = continuation
            if stopCaptureCompleted {
                finishStopIfPossible()
            } else {
                stream.stopCapture { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.stopCaptureCompleted = true
                        if let error { self.stopFailure = error }
                        self.finishStopIfPossible()
                    }
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard let self,
                      self.stopGeneration == generation,
                      self.stopContinuation != nil else { return }
                self.stopFailure = ScreenRecordingError.recordingDidNotFinalize
                self.stopCaptureCompleted = true
                self.recordingOutputFinished = true
                self.finishStopIfPossible()
            }
        }
    }

    private func makeCapturePipeline(
        source: RecordingCaptureSource,
        options: ScreenRecordingOptions,
        prepared: PreparedRecordingSource,
        dimensions: TraceDimensions,
        outputURL: URL
    ) throws -> (stream: SCStream, output: SCRecordingOutput) {
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(options.framesPerSecond, 1))
        )
        configuration.queueDepth = 8
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.capturesAudio = options.capturesSystemAudio
        configuration.excludesCurrentProcessAudio = true
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
        if options.capturesSystemAudio {
            try stream.addStreamOutput(
                systemAudioMonitor,
                type: .audio,
                sampleHandlerQueue: SystemAudioLevelMonitor.queue
            )
        }
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
        return (stream, output)
    }

    private func makeResumedSegmentPaths(
        index: Int,
        session: RecordingTraceSession,
        options: ScreenRecordingOptions
    ) throws -> RecordingSegmentPaths {
        let directory = session.packageURL.appendingPathComponent("raw/segments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = String(format: "%03d", index)
        return RecordingSegmentPaths(
            index: index,
            screenURL: directory.appendingPathComponent("screen-\(suffix).mp4"),
            microphoneURL: options.capturesMicrophone
                ? directory.appendingPathComponent("microphone-\(suffix).caf")
                : nil,
            cameraURL: options.capturesCamera
                ? directory.appendingPathComponent("camera-\(suffix).mov")
                : nil
        )
    }

    private func assembleScreenSegments(
        _ segments: [RecordingSegment],
        session: RecordingTraceSession
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
        session: RecordingTraceSession
    ) throws -> [RecordingSegment] {
        guard segments.count > 1,
              let firstPosition = segments.firstIndex(where: { $0.index == 0 }) else {
            return segments
        }
        let directory = session.packageURL.appendingPathComponent("raw/segments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var archived = segments[firstPosition]
        let archivedScreenURL = directory.appendingPathComponent("screen-000.mp4")
        try copyIfNeeded(session.videoURL, to: archivedScreenURL)
        archived = RecordingSegment(
            index: archived.index,
            timelineStartSeconds: archived.timelineStartSeconds,
            durationSeconds: archived.durationSeconds,
            screenRelativePath: relativePath(archivedScreenURL, in: session.packageURL),
            microphoneRelativePath: try archived.microphoneRelativePath.flatMap { _ in
                guard let microphoneURL = session.microphoneURL, microphoneURL.isNonemptyFile else {
                    return nil
                }
                let destination = directory.appendingPathComponent("microphone-000.caf")
                try copyIfNeeded(microphoneURL, to: destination)
                return relativePath(destination, in: session.packageURL)
            },
            cameraRelativePath: try archived.cameraRelativePath.flatMap { _ in
                guard let cameraURL = session.cameraURL, cameraURL.isNonemptyFile else { return nil }
                let destination = directory.appendingPathComponent("camera-000.mov")
                try copyIfNeeded(cameraURL, to: destination)
                return relativePath(destination, in: session.packageURL)
            }
        )
        try store.appendRecordingSegment(archived, to: session)
        var result = segments
        result[firstPosition] = archived
        return result
    }

    private func assembleOptionalTracks(
        _ segments: [RecordingSegment],
        session: RecordingTraceSession
    ) async {
        if let microphoneURL = session.microphoneURL {
            let urls = segments.compactMap(\.microphoneRelativePath).map {
                session.packageURL.appendingPathComponent($0)
            }.filter(\.isNonemptyFile)
            if !urls.isEmpty {
                do {
                    _ = try segmentAssembler.assembleAudioSegments(urls, outputURL: microphoneURL)
                    try store.upsertAsset(
                        TraceAsset(role: .microphone, relativePath: "raw/microphone.caf"),
                        in: session.packageURL
                    )
                } catch {
                    lastMicrophoneError = lastMicrophoneError ?? error
                }
            }
        }
        if let cameraURL = session.cameraURL {
            let urls = segments.compactMap(\.cameraRelativePath).map {
                session.packageURL.appendingPathComponent($0)
            }.filter(\.isNonemptyFile)
            if !urls.isEmpty {
                do {
                    _ = try await segmentAssembler.assembleVideoSegments(
                        urls,
                        outputURL: cameraURL,
                        fileType: .mov
                    )
                    try store.upsertAsset(
                        TraceAsset(role: .camera, relativePath: "raw/camera.mov"),
                        in: session.packageURL
                    )
                } catch {
                    lastCameraError = lastCameraError ?? error
                }
            }
        }
    }

    private func finishStopIfPossible() {
        guard stopCaptureCompleted, recordingOutputFinished, let continuation = stopContinuation else {
            return
        }
        stopContinuation = nil
        if let stopFailure {
            continuation.resume(throwing: stopFailure)
        } else {
            continuation.resume()
        }
    }

    private func clearActiveSegment() {
        stream = nil
        recordingOutput = nil
        currentSegmentPaths = nil
        activeSegmentStartedAtUptime = nil
        stopCaptureCompleted = false
        recordingOutputFinished = false
        stopFailure = nil
        stopContinuation = nil
        unexpectedCaptureFailure = nil
        streamStoppedUnexpectedly = false
        outputFinishedUnexpectedly = false
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
        systemAudioMeter.reset()
        microphoneMeter.reset()
    }

    private func removeEmptyOptionalTracks(
        paths: RecordingSegmentPaths,
        session: RecordingTraceSession
    ) {
        removeEmptyOptionalTrack(role: .microphone, paths: paths, session: session)
        removeEmptyOptionalTrack(role: .camera, paths: paths, session: session)
    }

    private func removeEmptyOptionalTrack(
        role: TraceAsset.Role,
        paths: RecordingSegmentPaths,
        session: RecordingTraceSession
    ) {
        let url = role == .microphone ? paths.microphoneURL : paths.cameraURL
        guard let url, !url.isNonemptyFile else { return }
        try? store.removeRecordingSegmentMedia(
            role: role,
            segmentIndex: paths.index,
            from: session
        )
    }

    private func validateNonemptyFile(at url: URL) throws {
        guard url.isNonemptyFile else { throw TraceProjectStoreError.emptyRawRecording }
    }

    private func relativePath(_ url: URL, in packageURL: URL) -> String {
        url.path.replacingOccurrences(of: packageURL.path + "/", with: "")
    }

    private func copyIfNeeded(_ sourceURL: URL, to destinationURL: URL) throws {
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try validateNonemptyFile(at: destinationURL)
            return
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
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

    private func prepare(
        source: RecordingCaptureSource,
        content: SCShareableContent
    ) throws -> PreparedRecordingSource {
        switch source.mode {
        case .display, .region:
            guard let displayID = source.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingError.displayUnavailable
            }
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
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
                  let window = content.windows.first(where: { $0.windowID == windowID }),
                  window.isOnScreen else {
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
    let dimensions: TraceDimensions
    let sourceRect: CGRect?
    let captureBounds: CGRect
    let trackedWindowID: CGWindowID?
}

extension ScreenRecordingService: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput else { return }
            if stopContinuation == nil {
                outputFinishedUnexpectedly = true
                unexpectedCaptureFailure = ScreenRecordingError.recordingDidNotFinalize
                return
            }
            recordingOutputFinished = true
            finishStopIfPossible()
        }
    }

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            guard self.recordingOutput === recordingOutput else { return }
            if stopContinuation == nil {
                outputFinishedUnexpectedly = true
                unexpectedCaptureFailure = error
                return
            }
            stopFailure = error
            recordingOutputFinished = true
            finishStopIfPossible()
        }
    }
}

extension ScreenRecordingService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            if stopContinuation == nil {
                streamStoppedUnexpectedly = true
                unexpectedCaptureFailure = error
                return
            }
            stopFailure = error
            stopCaptureCompleted = true
            recordingOutputFinished = true
            finishStopIfPossible()
        }
    }
}
