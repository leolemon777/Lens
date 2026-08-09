import AVFoundation
import Foundation

enum CameraTrackRecordingError: LocalizedError {
    case cameraUnavailable
    case inputUnavailable
    case outputUnavailable
    case startTimedOut
    case stopTimedOut
    case emptyTrack
    case missingVideoTrack

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "当前没有可用的摄像头。"
        case .inputUnavailable: "无法读取摄像头输入。"
        case .outputUnavailable: "无法创建摄像头原始轨道。"
        case .startTimedOut: "摄像头启动超时。"
        case .stopTimedOut: "摄像头轨道完成超时。"
        case .emptyTrack: "摄像头轨道没有写入有效数据。"
        case .missingVideoTrack: "摄像头文件不包含视频轨道。"
        }
    }
}

@MainActor
final class CameraTrackRecorder: NSObject {
    private var session: AVCaptureSession?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var outputURL: URL?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var startGeneration = 0
    private var stopGeneration = 0

    var isRecording: Bool { movieOutput?.isRecording == true }

    func start(outputURL: URL) async throws {
        await cancel()
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraTrackRecordingError.cameraUnavailable
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraTrackRecordingError.inputUnavailable
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraTrackRecordingError.inputUnavailable
        }
        session.addInput(input)
        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraTrackRecordingError.outputUnavailable
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        movieOutput = output
        self.outputURL = outputURL
        await setSession(session, running: true)
        guard session.isRunning else {
            clearState()
            throw CameraTrackRecordingError.cameraUnavailable
        }

        do {
            startGeneration += 1
            let generation = startGeneration
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                startContinuation = continuation
                output.startRecording(to: outputURL, recordingDelegate: self)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard let self,
                          self.startGeneration == generation,
                          let continuation = self.startContinuation else { return }
                    self.startContinuation = nil
                    continuation.resume(throwing: CameraTrackRecordingError.startTimedOut)
                }
            }
        } catch {
            await cancel()
            throw error
        }
    }

    func stop() async throws {
        guard let session, let movieOutput, let outputURL else { return }
        var finalizationError: Error?
        if movieOutput.isRecording {
            do {
                stopGeneration += 1
                let generation = stopGeneration
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    stopContinuation = continuation
                    movieOutput.stopRecording()
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(10))
                        guard let self,
                              self.stopGeneration == generation,
                              let continuation = self.stopContinuation else { return }
                        self.stopContinuation = nil
                        continuation.resume(throwing: CameraTrackRecordingError.stopTimedOut)
                    }
                }
            } catch {
                finalizationError = error
            }
        }
        await setSession(session, running: false)
        clearState()
        if let finalizationError {
            throw finalizationError
        }
        try await Self.validateVideoTrack(at: outputURL)
    }

    func cancel() async {
        startGeneration += 1
        stopGeneration += 1
        if let movieOutput, movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        if let session {
            await setSession(session, running: false)
        }
        if let continuation = startContinuation {
            startContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
        clearState()
    }

    static func validateVideoTrack(at url: URL) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw CameraTrackRecordingError.emptyTrack }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw CameraTrackRecordingError.missingVideoTrack }
    }

    private func setSession(_ session: AVCaptureSession, running: Bool) async {
        let box = CaptureSessionBox(session)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if running {
                    box.session.startRunning()
                } else {
                    box.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    private func clearState() {
        session = nil
        movieOutput = nil
        outputURL = nil
    }
}

extension CameraTrackRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in
            guard fileURL.standardizedFileURL == outputURL?.standardizedFileURL else {
                return
            }
            guard let continuation = startContinuation else { return }
            startContinuation = nil
            continuation.resume()
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor in
            guard outputFileURL.standardizedFileURL == outputURL?.standardizedFileURL else {
                return
            }
            let effectiveError: Error? = {
                guard let error else { return nil }
                let nsError = error as NSError
                if nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true {
                    return nil
                }
                return error
            }()
            if let continuation = startContinuation {
                startContinuation = nil
                if let effectiveError {
                    continuation.resume(throwing: effectiveError)
                } else {
                    continuation.resume()
                }
            }
            if let continuation = stopContinuation {
                stopContinuation = nil
                if let effectiveError {
                    continuation.resume(throwing: effectiveError)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private final class CaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession

    init(_ session: AVCaptureSession) {
        self.session = session
    }
}
