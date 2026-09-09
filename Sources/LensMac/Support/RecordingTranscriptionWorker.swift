import Foundation
import LensCore

enum RecordingTranscriptionAuthorization: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unknown
}

struct RecordingTranscriptionSource: Equatable, Sendable {
    let url: URL
    let role: LensAsset.Role
}

/// Stable input passed from task orchestration to the local transcription
/// implementation. Keeping the task token here makes phase and cancellation
/// ownership explicit before the implementation moves out of AppDelegate.
struct RecordingTranscriptionWorkRequest: Equatable, Sendable {
    let entry: LensLibraryEntry
    let automatic: Bool
    let taskToken: RecordingTaskToken

    init(
        entry: LensLibraryEntry,
        automatic: Bool,
        taskToken: RecordingTaskToken
    ) {
        self.entry = entry
        self.automatic = automatic
        self.taskToken = taskToken
    }
}

@MainActor
final class RecordingTranscriptionWorker {
    typealias Operation = @MainActor @Sendable (
        RecordingTranscriptionWorkRequest
    ) async throws -> TranscriptDocument
    typealias AuthorizationStatusProvider = @MainActor @Sendable () -> RecordingTranscriptionAuthorization
    typealias AuthorizationRequester = @Sendable () async -> RecordingTranscriptionAuthorization
    typealias SourceProvider = @MainActor @Sendable (
        LensLibraryEntry
    ) throws -> RecordingTranscriptionSource
    typealias PermissionPresenter = @MainActor @Sendable () -> Void
    typealias ToastPresenter = @MainActor @Sendable (
        _ title: String,
        _ detail: String,
        _ symbol: String
    ) -> Void
    typealias ProgressReporter = @MainActor @Sendable (
        _ lensID: UUID,
        _ completed: Int,
        _ total: Int
    ) -> Void
    typealias LocaleIdentifierProvider = @MainActor @Sendable () -> String
    typealias TranscriptionOperation = @MainActor @Sendable (
        _ audioURL: URL,
        _ localeIdentifier: String,
        _ sourceRole: LensAsset.Role,
        _ progress: @escaping (Int, Int) -> Void
    ) async throws -> TranscriptDocument

    private let operation: Operation

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    /// Keeps authorization, source selection, progress and user-facing
    /// failure boundaries injectable while the Speech.framework service stays
    /// in its existing platform implementation. The worker owns the policy;
    /// AppDelegate only supplies UI and service adapters.
    init(
        authorizationStatus: @escaping AuthorizationStatusProvider,
        requestAuthorization: @escaping AuthorizationRequester,
        source: @escaping SourceProvider,
        presentPermission: @escaping PermissionPresenter,
        presentToast: @escaping ToastPresenter,
        reportProgress: @escaping ProgressReporter,
        localeIdentifier: @escaping LocaleIdentifierProvider,
        transcribe: @escaping TranscriptionOperation
    ) {
        self.operation = { request in
            var status = authorizationStatus()
            if status == .notDetermined {
                status = await requestAuthorization()
            }
            switch status {
            case .authorized:
                break
            case .denied, .notDetermined:
                presentPermission()
                throw LocalSpeechTranscriptionError.authorizationDenied
            case .restricted, .unknown:
                presentPermission()
                throw LocalSpeechTranscriptionError.authorizationRestricted
            }

            let source = try source(request.entry)
            presentToast(
                "正在本机生成转写",
                "不会上传录屏或声音；完成后可直接搜索文字",
                "waveform.badge.magnifyingglass"
            )
            return try await transcribe(
                source.url,
                localeIdentifier(),
                source.role,
                { completed, total in
                    reportProgress(request.entry.id, completed, total)
                }
            )
        }
    }

    func run(
        _ request: RecordingTranscriptionWorkRequest
    ) async throws -> TranscriptDocument {
        try await operation(request)
    }
}
