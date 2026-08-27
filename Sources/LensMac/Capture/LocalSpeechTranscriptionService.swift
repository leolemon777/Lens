@preconcurrency import AVFoundation
import Foundation
import LensCore
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
            "语音识别权限尚未允许，可在 Lens 的设置与权限中开启。"
        case .authorizationRestricted:
            "这台 Mac 限制了语音识别权限。"
        case let .recognizerUnavailable(locale):
            "当前无法使用 \(locale) 语音识别器。"
        case let .onDeviceRecognitionUnavailable(locale):
            "\(locale) 尚不支持本机离线识别；Lens 不会自动改用云端转写。"
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
    private let chunkExporter = TranscriptionAudioChunkExporter()
    private var activeTask: SFSpeechRecognitionTask?
    private var activeGate: SpeechRecognitionContinuationGate?
    private var activeToken: UUID?

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    nonisolated static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization(
                authorizationCallback(continuation)
            )
        }
    }

    nonisolated static func authorizationCallback(
        _ continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
    ) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { @Sendable status in
            continuation.resume(returning: status)
        }
    }

    func transcribe(
        audioURL: URL,
        localeIdentifier: String,
        sourceRole: LensAsset.Role,
        progress: ((Int, Int) -> Void)? = nil
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
        let token = UUID()
        activeToken = token
        defer {
            if activeToken == token {
                activeTask = nil
                activeGate = nil
                activeToken = nil
            }
        }
        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        let chunks = TranscriptChunkPlanner.plan(durationSeconds: duration)
        guard !chunks.isEmpty else { throw LocalSpeechTranscriptionError.missingSource }
        let generatedAt = Date()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LensTranscription-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var chunkDocuments: [TranscriptChunkDocument] = []
        for chunk in chunks {
            try Task.checkCancellation()
            guard activeToken == token else { throw CancellationError() }
            let chunkURL = temporaryDirectory.appendingPathComponent(
                String(format: "speech-%03d.m4a", chunk.index)
            )
            _ = try await chunkExporter.export(
                inputURL: audioURL,
                chunk: chunk,
                outputURL: chunkURL
            )
            try Task.checkCancellation()
            guard activeToken == token else { throw CancellationError() }
            let document = try await recognize(
                audioURL: chunkURL,
                recognizer: recognizer,
                localeIdentifier: localeIdentifier,
                sourceRole: sourceRole,
                generatedAt: generatedAt,
                operationToken: token
            )
            chunkDocuments.append(TranscriptChunkDocument(
                chunk: chunk,
                document: document
            ))
            progress?(chunk.index + 1, chunks.count)
        }
        let document: TranscriptDocument
        if chunks.count == 1, let singleDocument = chunkDocuments.first?.document {
            document = singleDocument
        } else {
            document = TranscriptChunkMerger.merge(
                chunkDocuments,
                engine: "apple-speech",
                generatedAt: generatedAt,
                localeIdentifier: localeIdentifier,
                isOnDevice: true,
                sourceRole: sourceRole
            )
        }
        return try Self.validatedDocument(document)
    }

    private func recognize(
        audioURL: URL,
        recognizer: SFSpeechRecognizer,
        localeIdentifier: String,
        sourceRole: LensAsset.Role,
        generatedAt: Date,
        operationToken: UUID
    ) async throws -> TranscriptDocument {
        guard activeToken == operationToken else { throw CancellationError() }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        let gate = SpeechRecognitionContinuationGate()
        activeGate = gate
        defer {
            if activeToken == operationToken {
                activeTask = nil
                activeGate = nil
            }
        }
        return try await withTaskCancellationHandler {
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
                            sourceRole: sourceRole,
                            generatedAt: generatedAt
                        ))
                    } else if let error {
                        gate.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            gate.resume(throwing: CancellationError())
            Task { @MainActor [weak self] in
                guard self?.activeToken == operationToken else { return }
                self?.activeTask?.cancel()
            }
        }
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
        sourceRole: LensAsset.Role,
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

    nonisolated static func validatedDocument(
        _ document: TranscriptDocument
    ) throws -> TranscriptDocument {
        let hasText = !document.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !document.segments.isEmpty else {
            throw LocalSpeechTranscriptionError.noFinalResult
        }
        return document
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
