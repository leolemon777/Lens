import Foundation
import LensCore

/// Converts a completed task snapshot into the small, allowlisted diagnostic
/// event used by the UI layer. Snapshot loading and event recording are
/// injected so the reporting contract can be tested without launching Lens or
/// writing a diagnostic file.
@MainActor
final class RecordingTaskMetricsReporter {
    typealias SnapshotLoader = @Sendable (
        URL,
        RecordingTaskKind,
        String
    ) async -> RecordingTaskSnapshot?
    typealias DiagnosticRecorder = @MainActor @Sendable (
        String,
        DiagnosticLevel,
        [String: String]
    ) -> Void

    private let loadSnapshot: SnapshotLoader
    private let recordDiagnostic: DiagnosticRecorder

    init(
        loadSnapshot: @escaping SnapshotLoader,
        recordDiagnostic: @escaping DiagnosticRecorder
    ) {
        self.loadSnapshot = loadSnapshot
        self.recordDiagnostic = recordDiagnostic
    }

    func record(
        packageURL: URL,
        kind: RecordingTaskKind,
        version: String
    ) async {
        guard let snapshot = await loadSnapshot(packageURL, kind, version),
              let outcome = snapshot.outcome else {
            return
        }
        var metadata: [String: String] = [
            "taskKind": kind.rawValue,
            "taskOutcome": outcome.rawValue,
            "phase": snapshot.phase.rawValue
        ]
        if let reason = snapshot.cancellationReason {
            metadata["cancellationReason"] = reason.rawValue
        }
        if let queueMilliseconds = snapshot.queueDurationMilliseconds {
            metadata["queueMilliseconds"] = String(
                format: "%.0f",
                queueMilliseconds
            )
        }
        if let executionMilliseconds = snapshot.executionDurationMilliseconds {
            metadata["executionMilliseconds"] = String(
                format: "%.0f",
                executionMilliseconds
            )
        }
        let level: DiagnosticLevel = outcome == .failed ? .warning : .info
        recordDiagnostic(
            "task.\(kind.rawValue).\(outcome.rawValue)",
            level,
            metadata
        )
    }
}
