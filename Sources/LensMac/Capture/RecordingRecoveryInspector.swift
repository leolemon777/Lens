@preconcurrency import AVFoundation
import Foundation
import LensCore

/// Measures a finished recording's files and reports what it holds beyond what
/// it presents.
///
/// The store's existing recovery only revisits projects that never finished:
/// it moves `capturing` to `interrupted` and resumes those. A recording that
/// finalized while silently dropping a continuation segment reads as `ready`
/// and is therefore never looked at again, which is how playable footage ends
/// up unreachable inside an otherwise healthy looking project.
struct RecordingRecoveryInspector {
    private let store: LensProjectStore
    private let durationProvider: @Sendable (URL) async -> Double?

    init(
        store: LensProjectStore,
        durationProvider: @escaping @Sendable (URL) async -> Double? = {
            await Self.mediaDurationSeconds(at: $0)
        }
    ) {
        self.store = store
        self.durationProvider = durationProvider
    }

    func assess(packageURL: URL) async -> RecordingRecoveryAssessment? {
        guard let manifest = try? store.loadManifest(from: packageURL),
              manifest.kind == .recording else { return nil }
        let index = (try? store.loadRecordingSegmentIndex(from: packageURL))
            ?? RecordingSegmentIndex()

        var probes: [RecordingRecoveryProbe] = []
        var probedPaths: Set<String> = []

        for asset in manifest.assets where Self.isTimedRole(asset.role) {
            guard probedPaths.insert(asset.relativePath).inserted else { continue }
            probes.append(
                await probe(
                    relativePath: asset.relativePath,
                    role: asset.role,
                    in: packageURL
                )
            )
        }

        // Continuation media is not always declared in the manifest, and an
        // undeclared segment file is exactly the case worth finding.
        for segment in index.segments {
            for (path, role) in [
                (segment.screenRelativePath, LensAsset.Role.screenVideoSegment),
                (segment.microphoneRelativePath, .microphoneSegment),
                (segment.cameraRelativePath, .cameraSegment)
            ] {
                guard let path, probedPaths.insert(path).inserted else { continue }
                probes.append(
                    await probe(relativePath: path, role: role, in: packageURL)
                )
            }
        }

        return RecordingRecoveryPlanner.assess(
            index: index,
            declaredAssets: manifest.assets,
            probes: probes
        )
    }

    private func probe(
        relativePath: String,
        role: LensAsset.Role,
        in packageURL: URL
    ) async -> RecordingRecoveryProbe {
        let url = packageURL.appendingPathComponent(relativePath)
        let seconds = FileManager.default.fileExists(atPath: url.path)
            ? await durationProvider(url)
            : nil
        return RecordingRecoveryProbe(
            relativePath: relativePath,
            role: role,
            measuredSeconds: seconds
        )
    }

    /// Roles whose files carry a duration worth comparing. Event tracks, plans
    /// and reports are excluded: a missing one is a different problem.
    private static func isTimedRole(_ role: LensAsset.Role) -> Bool {
        switch role {
        case .screenVideo, .screenVideoSegment, .systemAudio, .microphone,
             .microphoneSegment, .camera, .cameraSegment:
            true
        default:
            false
        }
    }

    static func mediaDurationSeconds(at url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}
