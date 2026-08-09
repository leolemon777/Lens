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

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "已经在录制。"
        case .notRecording: "当前没有正在进行的录制。"
        case .displayUnavailable: "无法找到要录制的显示器。"
        case .windowUnavailable: "所选窗口已经关闭，请重新选择。"
        case .emptySelection: "录屏选区为空。"
        case .unableToAddRecordingOutput: "无法创建系统录制输出。"
        case .recordingDidNotFinalize: "系统未能及时完成录屏文件。"
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
    private let microphoneRecorder = MicrophoneTrackRecorder()
    private let cameraRecorder = CameraTrackRecorder()
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var session: RecordingTraceSession?
    private var startedAtUptime: TimeInterval?

    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var stopCaptureCompleted = false
    private var recordingOutputFinished = false
    private var stopFailure: Error?
    private(set) var lastMicrophoneError: Error?
    private(set) var lastCameraError: Error?

    init(store: TraceProjectStore, pointerRecorder: PointerEventRecorder) {
        self.store = store
        self.pointerRecorder = pointerRecorder
    }

    var isRecording: Bool { stream != nil }

    func start(
        source: RecordingCaptureSource,
        options: ScreenRecordingOptions = ScreenRecordingOptions()
    ) async throws -> RecordingTraceSession {
        guard stream == nil else { throw ScreenRecordingError.alreadyRecording }
        lastMicrophoneError = nil
        lastCameraError = nil

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
            includesMicrophone: options.capturesMicrophone,
            includesCamera: options.capturesCamera
        )

        do {
            let configuration = SCStreamConfiguration()
            configuration.width = prepared.dimensions.width
            configuration.height = prepared.dimensions.height
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
            // Narration is recorded into a physically separate local track below.
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
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = session.videoURL
            outputConfiguration.videoCodecType = .h264
            outputConfiguration.outputFileType = .mp4
            let recordingOutput = SCRecordingOutput(
                configuration: outputConfiguration,
                delegate: self
            )
            try stream.addRecordingOutput(recordingOutput)

            if let microphoneURL = session.microphoneURL {
                try microphoneRecorder.start(outputURL: microphoneURL)
            }
            if let cameraURL = session.cameraURL {
                try await cameraRecorder.start(outputURL: cameraURL)
            }

            try pointerRecorder.start(
                session: session,
                captureBounds: prepared.captureBounds,
                trackedWindowID: prepared.trackedWindowID
            )
            try await startCapture(stream)

            self.stream = stream
            self.recordingOutput = recordingOutput
            self.session = session
            startedAtUptime = ProcessInfo.processInfo.systemUptime
            return session
        } catch {
            await cameraRecorder.cancel()
            microphoneRecorder.cancel()
            removeEmptyMicrophoneAsset(from: session)
            removeEmptyCameraAsset(from: session)
            await pointerRecorder.stop()
            try? store.markRecordingInterrupted(session)
            throw error
        }
    }

    func stop() async throws -> SavedTrace {
        guard let stream, let session else { throw ScreenRecordingError.notRecording }
        let duration = max(0, ProcessInfo.processInfo.systemUptime - (startedAtUptime ?? 0))

        do {
            try microphoneRecorder.stop()
        } catch {
            lastMicrophoneError = error
            removeEmptyMicrophoneAsset(from: session)
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

        stopCaptureCompleted = false
        recordingOutputFinished = false
        stopFailure = nil

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stopContinuation = continuation
                stream.stopCapture { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.stopCaptureCompleted = true
                        if let error { self.stopFailure = error }
                        self.finishStopIfPossible()
                    }
                }

                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard let self, self.stopContinuation != nil else { return }
                    self.stopFailure = ScreenRecordingError.recordingDidNotFinalize
                    self.stopCaptureCompleted = true
                    self.recordingOutputFinished = true
                    self.finishStopIfPossible()
                }
            }
            await pointerRecorder.stop()
            if let cameraError = await cameraStopTask.value {
                lastCameraError = cameraError
                removeEmptyCameraAsset(from: session)
            }
            // 自动处理失败绝不能让已经完成的原始录屏变成失败状态。
            // beginRecording 已经写入一份可重试的默认 edit-plan。
            _ = try? store.writeAutoEditPlan(for: session, durationSeconds: duration)
            let saved = try store.finalizeRecording(session, durationSeconds: duration)
            clearActiveSession()
            return saved
        } catch {
            await pointerRecorder.stop()
            if let cameraError = await cameraStopTask.value {
                lastCameraError = cameraError
                removeEmptyCameraAsset(from: session)
            }
            try? store.markRecordingInterrupted(session)
            clearActiveSession()
            throw error
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

    private func clearActiveSession() {
        stream = nil
        recordingOutput = nil
        session = nil
        startedAtUptime = nil
        stopCaptureCompleted = false
        recordingOutputFinished = false
        stopFailure = nil
        stopContinuation = nil
    }

    private func removeEmptyMicrophoneAsset(from session: RecordingTraceSession) {
        guard let microphoneURL = session.microphoneURL else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: microphoneURL.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        guard size == 0 else { return }
        try? store.removeAsset(role: .microphone, from: session.packageURL)
    }

    private func removeEmptyCameraAsset(from session: RecordingTraceSession) {
        guard let cameraURL = session.cameraURL else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: cameraURL.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        guard size == 0 else { return }
        try? store.removeAsset(role: .camera, from: session.packageURL)
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
            recordingOutputFinished = true
            finishStopIfPossible()
        }
    }

    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in
            stopFailure = error
            recordingOutputFinished = true
            finishStopIfPossible()
        }
    }
}

extension ScreenRecordingService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            stopFailure = error
            stopCaptureCompleted = true
            recordingOutputFinished = true
            finishStopIfPossible()
        }
    }
}
