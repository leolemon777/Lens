import Foundation
import ScreenTraceCore
@preconcurrency import Speech

enum LocalSpeechTranscriptionError: LocalizedError, Equatable {
    case missingSource
    case authorizationDenied
    case authorizationRestricted
    case recognizerUnavailable(String)
    case onDeviceRecognitionUnavailable(String)
    case noFinalResult

    var errorDescription: String? {
        switch self {
        case .missingSource:
            "找不到可供转写的本地音轨。"
        case .authorizationDenied:
            "语音识别权限尚未允许，可在屏迹的设置与权限中开启。"
        case .authorizationRestricted:
            "这台 Mac 限制了语音识别权限。"
        case let .recognizerUnavailable(locale):
            "当前无法使用 \(locale) 语音识别器。"
        case let .onDeviceRecognitionUnavailable(locale):
            "\(locale) 尚不支持本机离线识别；屏迹不会自动改用云端转写。"
        case .noFinalResult:
            "本机语音识别没有返回最终结果。"
        }
    }
}

struct LocalSpeechSegment: Equatable, Sendable {
    let startSeconds: Double
    let durationSeconds: Double
    let text: String
    let confidence: Double
}

@MainActor
final class LocalSpeechTranscriptionService {
    private var activeTask: SFSpeechRecognitionTask?
    private var activeGate: SpeechRecognitionContinuationGate?
    private var activeToken: UUID?

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        sourceRole: TraceAsset.Role
    ) async throws -> TranscriptDocument {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw LocalSpeechTranscriptionError.missingSource
        }
        switch Self.authorizationStatus {
        case .authorized:
            break
        case .denied, .notDetermined:
            throw LocalSpeechTranscriptionError.authorizationDenied
        case .restricted:
            throw LocalSpeechTranscriptionError.authorizationRestricted
        @unknown default:
            throw LocalSpeechTranscriptionError.authorizationRestricted
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw LocalSpeechTranscriptionError.recognizerUnavailable(localeIdentifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw LocalSpeechTranscriptionError.onDeviceRecognitionUnavailable(localeIdentifier)
        }

        cancel()
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        let token = UUID()
        let gate = SpeechRecognitionContinuationGate()
        activeToken = token
        activeGate = gate
        defer {
            if activeToken == token {
                activeTask = nil
                activeGate = nil
                activeToken = nil
            }
        }
        let document = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<TranscriptDocument, Error>) in
                gate.install(continuation)
                activeTask = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let transcription = result.bestTranscription
                        gate.resume(returning: Self.makeDocument(
                            fullText: transcription.formattedString,
                            segments: transcription.segments.map {
                                LocalSpeechSegment(
                                    startSeconds: $0.timestamp,
                                    durationSeconds: $0.duration,
                                    text: $0.substring,
                                    confidence: Double($0.confidence)
                                )
                            },
                            localeIdentifier: localeIdentifier,
                            sourceRole: sourceRole
                        ))
                    } else if let error {
                        gate.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            gate.resume(throwing: CancellationError())
            Task { @MainActor [weak self] in
                guard self?.activeToken == token else { return }
                self?.activeTask?.cancel()
            }
        }
        return document
    }

    func cancel() {
        activeTask?.cancel()
        activeGate?.resume(throwing: CancellationError())
        activeTask = nil
        activeGate = nil
        activeToken = nil
    }

    nonisolated static func makeDocument(
        fullText: String,
        segments: [LocalSpeechSegment],
        localeIdentifier: String,
        sourceRole: TraceAsset.Role,
        generatedAt: Date = Date()
    ) -> TranscriptDocument {
        TranscriptDocument(
            engine: "apple-speech",
            generatedAt: generatedAt,
            localeIdentifier: localeIdentifier,
            isOnDevice: true,
            sourceRole: sourceRole,
            fullText: fullText,
            segments: segments.map {
                TranscriptSegment(
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.startSeconds + max($0.durationSeconds, 0),
                    text: $0.text,
                    confidence: $0.confidence
                )
            }
        )
    }
}

private final class SpeechRecognitionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TranscriptDocument, Error>?
    private var pendingResult: Result<TranscriptDocument, Error>?

    func install(_ continuation: CheckedContinuation<TranscriptDocument, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(returning document: TranscriptDocument) {
        resolve(.success(document))
    }

    func resume(throwing error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<TranscriptDocument, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else if pendingResult == nil {
            pendingResult = result
            lock.unlock()
        } else {
            lock.unlock()
        }
    }
}
