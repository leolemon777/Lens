import Foundation

/// The post-recording pipeline is deliberately described as data. The UI can
/// show a queued or cancelled job without knowing which worker is currently
/// reading media from disk.
enum RecordingTaskKind: String, Codable, Equatable, Sendable {
    case render
    case transcription
    case organization
    case recovery
}

enum RecordingTaskPhase: String, Codable, Equatable, Sendable {
    case queued
    case audioPreparation
    case transcription
    case organization
    case effects
    case verification
    case publishing
    case completed
    case cancelled
    case failed
}

enum RecordingTaskOutcome: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

enum RecordingTaskCancellationReason: String, Codable, Equatable, Sendable {
    case superseded
    case operationCancelled
    case packageGateUnavailable
    case userRequested
}

enum RecordingTaskPriority: Int, Codable, Comparable, Sendable {
    case background = 0
    case userInitiated = 50
    case recordingFinalization = 100

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum RecordingTaskSchedulingPolicy {
    static let maximumConcurrentTranscriptions = 1

    enum Admission: Equatable, Sendable {
        case start
        case deferredWhileRecording
        case alreadyQueued
        case atCapacity
    }

    static func shouldDefer(
        priority: RecordingTaskPriority,
        whileRecording isRecording: Bool
    ) -> Bool {
        isRecording && priority < .recordingFinalization
    }

    static func admission(
        priority: RecordingTaskPriority,
        whileRecording isRecording: Bool,
        isActive: Bool,
        isPending: Bool,
        activeCount: Int,
        maximumConcurrent: Int = maximumConcurrentTranscriptions
    ) -> Admission {
        if isActive || isPending {
            return .alreadyQueued
        }
        if shouldDefer(priority: priority, whileRecording: isRecording) {
            return .deferredWhileRecording
        }
        if activeCount >= maximumConcurrent {
            return .atCapacity
        }
        return .start
    }
}

struct RecordingTaskToken: Hashable, Sendable {
    let id: UUID
    let packageURL: URL
    let kind: RecordingTaskKind
    let version: String
}

struct RecordingTaskSnapshot: Equatable, Sendable {
    let token: RecordingTaskToken
    let priority: RecordingTaskPriority
    let phase: RecordingTaskPhase
    let queuedAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let outcome: RecordingTaskOutcome?
    let cancellationReason: RecordingTaskCancellationReason?

    var queueDurationMilliseconds: Double? {
        guard let startedAt else { return nil }
        return max(startedAt.timeIntervalSince(queuedAt) * 1_000, 0)
    }

    var executionDurationMilliseconds: Double? {
        guard let startedAt, let finishedAt else { return nil }
        return max(finishedAt.timeIntervalSince(startedAt) * 1_000, 0)
    }
}

/// Owns identity, duplicate coalescing, cancellation state, and phase timing
/// for background work. The actual media workers remain platform-specific and
/// can be moved out of AppDelegate incrementally without changing this
/// contract.
actor RecordingTaskCoordinator {
    private struct TaskKey: Hashable {
        let packageURL: URL
        let kind: RecordingTaskKind
    }

    private struct State {
        let token: RecordingTaskToken
        let priority: RecordingTaskPriority
        let queuedAt: Date
        var startedAt: Date?
        var finishedAt: Date?
        var phase: RecordingTaskPhase
        var outcome: RecordingTaskOutcome?
        var cancellationReason: RecordingTaskCancellationReason?

        var snapshot: RecordingTaskSnapshot {
            RecordingTaskSnapshot(
                token: token,
                priority: priority,
                phase: phase,
                queuedAt: queuedAt,
                startedAt: startedAt,
                finishedAt: finishedAt,
                outcome: outcome,
                cancellationReason: cancellationReason
            )
        }
    }

    private struct BeginResult {
        let token: RecordingTaskToken
        let isNew: Bool
    }

    private var activeByKey: [TaskKey: State] = [:]
    private var history: [RecordingTaskSnapshot] = []
    private let historyLimit = 100
    private let packageGate = RecordingProcessingGate()

    /// Runs one worker behind the task identity and records its terminal
    /// outcome in one place. The operation is isolated to the main actor when
    /// it needs AppKit, while this coordinator retains ownership of the task
    /// lifecycle and remains independently fault-testable.
    ///
    /// A caller can still advance the supplied token through the concrete
    /// phases. Errors are rethrown so the UI can choose its user-facing copy;
    /// cancellation is classified separately in the history.
    func run<T: Sendable>(
        packageURL: URL,
        kind: RecordingTaskKind,
        version: String,
        priority: RecordingTaskPriority,
        now: Date = Date(),
        serializePackage: Bool = false,
        operation: @escaping @MainActor @Sendable (RecordingTaskToken) async throws -> T
    ) async throws -> T {
        let reservation = beginTask(
            packageURL: packageURL,
            kind: kind,
            version: version,
            priority: priority,
            now: now
        )
        // The caller-level registry owns the shared worker. If the same
        // package, kind, and version is already running, do not execute a
        // second closure against the same project and media files.
        guard reservation.isNew else { throw CancellationError() }
        let token = reservation.token
        let ownsPackageGate = serializePackage
            ? await packageGate.acquire(packageURL.standardizedFileURL)
            : false
        if serializePackage, !ownsPackageGate {
            finish(
                token,
                outcome: .cancelled,
                cancellationReason: .packageGateUnavailable
            )
            throw CancellationError()
        }
        do {
            let value = try await operation(token)
            if ownsPackageGate {
                await packageGate.release(packageURL.standardizedFileURL)
            }
            finish(token, outcome: .completed)
            return value
        } catch is CancellationError {
            if ownsPackageGate {
                await packageGate.release(packageURL.standardizedFileURL)
            }
            finish(
                token,
                outcome: .cancelled,
                cancellationReason: .operationCancelled
            )
            throw CancellationError()
        } catch {
            if ownsPackageGate {
                await packageGate.release(packageURL.standardizedFileURL)
            }
            finish(token, outcome: .failed)
            throw error
        }
    }

    /// A request with the same package, kind, and version shares the active
    /// token. A newer version supersedes the old one and records cancellation
    /// before taking ownership.
    func begin(
        packageURL: URL,
        kind: RecordingTaskKind,
        version: String,
        priority: RecordingTaskPriority,
        now: Date = Date()
    ) -> RecordingTaskToken {
        beginTask(
            packageURL: packageURL,
            kind: kind,
            version: version,
            priority: priority,
            now: now
        ).token
    }

    private func beginTask(
        packageURL: URL,
        kind: RecordingTaskKind,
        version: String,
        priority: RecordingTaskPriority,
        now: Date
    ) -> BeginResult {
        let normalizedPackageURL = packageURL.standardizedFileURL
        let key = TaskKey(packageURL: normalizedPackageURL, kind: kind)
        if let current = activeByKey[key],
           current.token.kind == kind,
           current.token.version == version,
           current.outcome == nil {
            return BeginResult(token: current.token, isNew: false)
        }
        if let current = activeByKey[key] {
            var cancelled = current
            cancelled.phase = .cancelled
            cancelled.outcome = .cancelled
            cancelled.cancellationReason = .superseded
            cancelled.finishedAt = now
            appendHistory(cancelled.snapshot)
        }
        let token = RecordingTaskToken(
            id: UUID(),
            packageURL: normalizedPackageURL,
            kind: kind,
            version: version
        )
        activeByKey[key] = State(
            token: token,
            priority: priority,
            queuedAt: now,
            startedAt: nil,
            finishedAt: nil,
            phase: .queued,
            outcome: nil,
            cancellationReason: nil
        )
        return BeginResult(token: token, isNew: true)
    }

    func advance(_ token: RecordingTaskToken, to phase: RecordingTaskPhase, now: Date = Date()) {
        let key = TaskKey(packageURL: token.packageURL, kind: token.kind)
        guard var state = activeByKey[key],
              state.token == token,
              state.outcome == nil else { return }
        if state.startedAt == nil, phase != .queued {
            state.startedAt = now
        }
        state.phase = phase
        activeByKey[key] = state
    }

    func finish(
        _ token: RecordingTaskToken,
        outcome: RecordingTaskOutcome,
        cancellationReason: RecordingTaskCancellationReason? = nil,
        now: Date = Date()
    ) {
        let key = TaskKey(packageURL: token.packageURL, kind: token.kind)
        guard var state = activeByKey[key],
              state.token == token,
              state.outcome == nil else { return }
        state.outcome = outcome
        state.cancellationReason = outcome == .cancelled
            ? cancellationReason
            : nil
        state.finishedAt = now
        state.phase = switch outcome {
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
        appendHistory(state.snapshot)
        activeByKey[key] = nil
    }

    func cancel(packageURL: URL, now: Date = Date()) {
        let normalizedPackageURL = packageURL.standardizedFileURL
        let tokens = activeByKey.values
            .filter { $0.token.packageURL == normalizedPackageURL }
            .map(\.token)
        for token in tokens {
            finish(
                token,
                outcome: .cancelled,
                cancellationReason: .userRequested,
                now: now
            )
        }
    }

    func activeSnapshots() -> [RecordingTaskSnapshot] {
        activeByKey.values.map(\.snapshot).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.queuedAt < $1.queuedAt
        }
    }

    func recentSnapshots() -> [RecordingTaskSnapshot] {
        history
    }

    func snapshot(
        packageURL: URL,
        kind: RecordingTaskKind,
        version: String
    ) -> RecordingTaskSnapshot? {
        let normalizedPackageURL = packageURL.standardizedFileURL
        let key = TaskKey(packageURL: normalizedPackageURL, kind: kind)
        if let active = activeByKey[key], active.token.version == version {
            return active.snapshot
        }
        return history.reversed().first {
            $0.token.packageURL == normalizedPackageURL
                && $0.token.kind == kind
                && $0.token.version == version
        }
    }

    private func appendHistory(_ snapshot: RecordingTaskSnapshot) {
        history.append(snapshot)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }
}
