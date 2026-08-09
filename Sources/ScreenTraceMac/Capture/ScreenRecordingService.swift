import AppKit
import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import ScreenTraceCore

enum ScreenRecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case displayUnavailable
    case unableToAddRecordingOutput
    case recordingDidNotFinalize

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "已经在录制。"
        case .notRecording: "当前没有正在进行的录制。"
        case .displayUnavailable: "无法找到要录制的显示器。"
        case .unableToAddRecordingOutput: "无法创建系统录制输出。"
        case .recordingDidNotFinalize: "系统未能及时完成录屏文件。"
        }
    }
}

struct ScreenRecordingOptions: Sendable {
    var framesPerSecond = 60
    var capturesSystemAudio = true
    var capturesMicrophone = false
}

@MainActor
final class ScreenRecordingService: NSObject {
    private let store: TraceProjectStore
    private let pointerRecorder: PointerEventRecorder
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var session: RecordingTraceSession?
    private var startedAtUptime: TimeInterval?

    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var stopCaptureCompleted = false
    private var recordingOutputFinished = false
    private var stopFailure: Error?

    init(store: TraceProjectStore, pointerRecorder: PointerEventRecorder) {
        self.store = store
        self.pointerRecorder = pointerRecorder
    }

    var isRecording: Bool { stream != nil }

    func start(
        displayID: CGDirectDisplayID,
        options: ScreenRecordingOptions = ScreenRecordingOptions()
    ) async throws -> RecordingTraceSession {
        guard stream == nil else { throw ScreenRecordingError.alreadyRecording }

        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecordingError.displayUnavailable
        }

        let width = max(Int(CGDisplayPixelsWide(displayID)), 1)
        let height = max(Int(CGDisplayPixelsHigh(displayID)), 1)
        let session = try store.beginRecording(width: width, height: height)

        do {
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
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
            configuration.captureMicrophone = options.capturesMicrophone
            configuration.captureResolution = .best

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = session.videoURL
            outputConfiguration.videoCodecType = .h264
            outputConfiguration.outputFileType = .mp4
            let recordingOutput = SCRecordingOutput(
                configuration: outputConfiguration,
                delegate: self
            )
            try stream.addRecordingOutput(recordingOutput)

            try pointerRecorder.start(session: session, displayID: displayID)
            try await startCapture(stream)

            self.stream = stream
            self.recordingOutput = recordingOutput
            self.session = session
            startedAtUptime = ProcessInfo.processInfo.systemUptime
            return session
        } catch {
            await pointerRecorder.stop()
            try? store.markRecordingInterrupted(session)
            throw error
        }
    }

    func stop() async throws -> SavedTrace {
        guard let stream, let session else { throw ScreenRecordingError.notRecording }
        let duration = max(0, ProcessInfo.processInfo.systemUptime - (startedAtUptime ?? 0))

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
            // 自动处理失败绝不能让已经完成的原始录屏变成失败状态。
            // beginRecording 已经写入一份可重试的默认 edit-plan。
            _ = try? store.writeAutoEditPlan(for: session, durationSeconds: duration)
            let saved = try store.finalizeRecording(session, durationSeconds: duration)
            clearActiveSession()
            return saved
        } catch {
            await pointerRecorder.stop()
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
