@preconcurrency import AVFoundation
import Foundation
import LensCore

enum RecordingRecoveryRepairError: LocalizedError {
    case nothingToRebuild
    case missingSegmentMedia(String)

    var errorDescription: String? {
        switch self {
        case .nothingToRebuild:
            "这条录屏没有可以并入成片的额外画面。"
        case let .missingSegmentMedia(path):
            "分片文件缺失：\(path)"
        }
    }
}

struct RebuiltRecording: Equatable, Sendable {
    let packageURL: URL
    let previousDurationSeconds: Double
    let durationSeconds: Double

    var addedSeconds: Double { max(0, durationSeconds - previousDurationSeconds) }
}

/// Merges continuation segments a finished recording never counted back into
/// its screen video.
///
/// The repair is additive and runs in place only after the user confirms.
/// Segment zero's original video is archived beside the other segments before
/// the merged result takes its path, so every frame that was on disk before
/// still is afterwards. That mirrors what an ordinary stop already does, which
/// is also why the outcome is a project the normal pipeline can process rather
/// than a special case.
@MainActor
struct RecordingRecoveryRepair {
    private let store: LensProjectStore
    private let assembler: RecordingSegmentAssembler
    private let durationProvider: @Sendable (URL) async -> Double?

    init(
        store: LensProjectStore,
        assembler: RecordingSegmentAssembler = RecordingSegmentAssembler(),
        durationProvider: @escaping @Sendable (URL) async -> Double? = {
            await RecordingRecoveryInspector.mediaDurationSeconds(at: $0)
        }
    ) {
        self.store = store
        self.assembler = assembler
        self.durationProvider = durationProvider
    }

    func rebuild(
        packageURL: URL,
        assessment: RecordingRecoveryAssessment
    ) async throws -> RebuiltRecording {
        guard assessment.canRebuildLongerRecording else {
            throw RecordingRecoveryRepairError.nothingToRebuild
        }
        let manifest = try store.loadManifest(from: packageURL)
        let session = Self.session(for: packageURL, manifest: manifest)
        let previousDuration = manifest.durationSeconds ?? 0

        var index = try store.loadRecordingSegmentIndex(from: packageURL)

        // Measure whatever the index never recorded, so the timeline finally
        // matches the media.
        for segment in index.segments where segment.durationSeconds == nil {
            let url = packageURL.appendingPathComponent(segment.screenRelativePath)
            guard let seconds = await durationProvider(url) else {
                throw RecordingRecoveryRepairError
                    .missingSegmentMedia(segment.screenRelativePath)
            }
            index = try store.completeRecordingSegment(
                index: segment.index,
                durationSeconds: seconds,
                in: session
            )
        }

        index = try archiveLeadingSegmentIfNeeded(index, session: session)

        let segments = index.segments.sorted { $0.index < $1.index }
        let screenURLs = segments.map {
            packageURL.appendingPathComponent($0.screenRelativePath)
        }
        for url in screenURLs where !FileManager.default.fileExists(atPath: url.path) {
            throw RecordingRecoveryRepairError
                .missingSegmentMedia(url.lastPathComponent)
        }
        _ = try await assembler.assembleVideoSegments(
            screenURLs,
            outputURL: session.videoURL,
            fileType: .mp4
        )
        await assembleSideTracks(segments, session: session)

        let duration = segments.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
        // Handing the project back as `processing` lets the ordinary
        // post-processing path regenerate the preview and plan, instead of
        // recovery growing its own copy of that pipeline.
        _ = try store.finalizeRecording(
            session,
            durationSeconds: duration,
            state: .processing
        )
        return RebuiltRecording(
            packageURL: packageURL,
            previousDurationSeconds: previousDuration,
            durationSeconds: duration
        )
    }

    /// Segment zero still points at `raw/screen.mp4` when a stop failed before
    /// archiving. Copying it beside the other segments first means the merge
    /// never reads the file it is about to overwrite.
    private func archiveLeadingSegmentIfNeeded(
        _ index: RecordingSegmentIndex,
        session: RecordingLensSession
    ) throws -> RecordingSegmentIndex {
        guard index.segments.count > 1,
              let leading = index.segments.first(where: { $0.index == 0 }),
              leading.screenRelativePath == Self.screenRelativePath
        else { return index }

        let directory = session.packageURL
            .appendingPathComponent("raw/segments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let archivedPath = "raw/segments/screen-000.mp4"
        let archivedURL = session.packageURL.appendingPathComponent(archivedPath)
        if !FileManager.default.fileExists(atPath: archivedURL.path) {
            try FileManager.default.copyItem(at: session.videoURL, to: archivedURL)
        }
        try store.appendRecordingSegment(
            RecordingSegment(
                index: leading.index,
                timelineStartSeconds: leading.timelineStartSeconds,
                durationSeconds: leading.durationSeconds,
                screenRelativePath: archivedPath,
                microphoneRelativePath: leading.microphoneRelativePath,
                cameraRelativePath: leading.cameraRelativePath
            ),
            to: session
        )
        return try store.loadRecordingSegmentIndex(from: session.packageURL)
    }

    /// Side tracks are clipped to their own segment's screen duration, because
    /// a microphone that outran a dead screen stream would otherwise push
    /// everything after it out of sync.
    private func assembleSideTracks(
        _ segments: [RecordingSegment],
        session: RecordingLensSession
    ) async {
        if let microphoneURL = session.microphoneURL {
            await assemble(
                segments.compactMap { segment in
                    segment.microphoneRelativePath.flatMap { path in
                        segment.durationSeconds.map { (path, $0) }
                    }
                },
                to: microphoneURL,
                fileType: .caf,
                in: session
            )
        }
        if let cameraURL = session.cameraURL {
            await assemble(
                segments.compactMap { segment in
                    segment.cameraRelativePath.flatMap { path in
                        segment.durationSeconds.map { (path, $0) }
                    }
                },
                to: cameraURL,
                fileType: .mov,
                in: session
            )
        }
    }

    private func assemble(
        _ sources: [(String, Double)],
        to outputURL: URL,
        fileType: AVFileType,
        in session: RecordingLensSession
    ) async {
        let existing = sources.compactMap { path, duration -> (URL, Double)? in
            let url = session.packageURL.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path)
                ? (url, duration)
                : nil
        }
        guard !existing.isEmpty else { return }
        // A failed side track must not fail the rebuild: the picture is the
        // part the user came back for.
        if fileType == .caf {
            _ = try? await assembler.assembleAudioSegments(
                existing.map(\.0),
                outputURL: outputURL,
                maximumDurations: existing.map(\.1)
            )
        } else {
            _ = try? await assembler.assembleVideoSegments(
                existing.map(\.0),
                outputURL: outputURL,
                fileType: fileType,
                maximumDurations: existing.map(\.1)
            )
        }
    }

    private static let screenRelativePath = "raw/screen.mp4"

    static func session(
        for packageURL: URL,
        manifest: LensManifest
    ) -> RecordingLensSession {
        func url(_ path: String) -> URL {
            packageURL.appendingPathComponent(path)
        }
        func declared(_ role: LensAsset.Role) -> URL? {
            manifest.assets.first { $0.role == role }.map { url($0.relativePath) }
        }
        return RecordingLensSession(
            packageURL: packageURL,
            videoURL: url(screenRelativePath),
            pointerEventsURL: url("events/pointer.jsonl"),
            clickEventsURL: url("events/clicks.jsonl"),
            keyboardEventsURL: url("events/keyboard.jsonl"),
            windowEventsURL: url("events/windows.jsonl"),
            segmentIndexURL: url("events/segments.json"),
            editPlanURL: url("edits/edit-plan.json"),
            microphoneURL: declared(.microphone),
            cameraURL: declared(.camera),
            manifest: manifest
        )
    }
}
