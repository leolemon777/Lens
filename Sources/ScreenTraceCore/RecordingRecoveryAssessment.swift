import Foundation

/// One media file measured from the media itself rather than from the
/// manifest. The manifest disagreeing with what is on disk is the entire
/// subject of a recovery assessment, so it cannot be the source of truth here.
public struct RecordingRecoveryProbe: Equatable, Sendable {
    public let relativePath: String
    public let role: TraceAsset.Role
    /// Nil when the file the manifest promised is not on disk.
    public let measuredSeconds: Double?

    public init(
        relativePath: String,
        role: TraceAsset.Role,
        measuredSeconds: Double?
    ) {
        self.relativePath = relativePath
        self.role = role
        self.measuredSeconds = measuredSeconds.flatMap {
            $0.isFinite && $0 >= 0 ? $0 : nil
        }
    }
}

/// What a finished recording holds on disk beyond what it presents.
public struct RecordingRecoveryAssessment: Equatable, Sendable {
    public enum Finding: Equatable, Hashable, Sendable {
        /// A continuation segment holds playable screen media that the index
        /// never recorded a duration for. Nothing downstream can see it,
        /// because the timeline is derived from those durations.
        case unindexedScreenSegment(index: Int, seconds: Double)

        /// The screen stream stopped while a side track kept writing. There is
        /// no more picture to recover here: the honest outcome is telling the
        /// user their microphone or camera holds material the screen does not.
        case sideTrackOutlivesScreen(
            role: TraceAsset.Role,
            relativePath: String,
            screenSeconds: Double,
            trackSeconds: Double
        )

        /// The manifest promises a file that is not on disk.
        case missingDeclaredAsset(relativePath: String, role: TraceAsset.Role)
    }

    public let findings: [Finding]
    /// Screen time the project currently presents.
    public let presentedScreenSeconds: Double
    /// Screen time actually playable on disk.
    public let availableScreenSeconds: Double

    public init(
        findings: [Finding],
        presentedScreenSeconds: Double,
        availableScreenSeconds: Double
    ) {
        self.findings = findings
        self.presentedScreenSeconds = max(0, presentedScreenSeconds)
        self.availableScreenSeconds = max(0, availableScreenSeconds)
    }

    public var isDamaged: Bool { !findings.isEmpty }

    /// Extra picture a rebuild would add. Zero for a recording whose only
    /// problem is a side track that outlived the screen.
    public var recoverableScreenSeconds: Double {
        max(0, availableScreenSeconds - presentedScreenSeconds)
    }

    /// Whether rebuilding would actually produce a longer recording. Disclosure
    /// alone is the right outcome otherwise.
    public var canRebuildLongerRecording: Bool {
        recoverableScreenSeconds >= RecordingRecoveryPlanner.tolerance
    }
}

public enum RecordingRecoveryPlanner {
    /// Matches the drift the recording health report already treats as
    /// meaningful, so the two never disagree about the same recording.
    public static let tolerance: Double = 0.15

    /// A side track almost always outlives the screen a little, because the
    /// devices do not stop on the same instant. Measured across a real library,
    /// an ordinary tail is one to four seconds and a camera can trail by as
    /// little as a quarter second, while a screen stream that actually died
    /// mid-recording left a track several times longer than the picture.
    ///
    /// Both bounds have to be crossed. Absolute alone would report every long
    /// recording's ordinary tail, and relative alone would report a two second
    /// tail on a five second clip. Reporting either would train the user to
    /// ignore the badge, which costs more than staying quiet.
    public static let sideTrackAbsoluteThreshold: Double = 3
    public static let sideTrackRelativeThreshold: Double = 0.25

    /// Compare what a finished recording presents against what its files hold.
    ///
    /// This deliberately does not look at `TraceState`. The damage worth
    /// finding here already passed finalization and reads as `ready`, so state
    /// based recovery never revisits it.
    public static func assess(
        index: RecordingSegmentIndex,
        declaredAssets: [TraceAsset],
        probes: [RecordingRecoveryProbe]
    ) -> RecordingRecoveryAssessment {
        let probesByPath = Dictionary(
            probes.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var findings: [RecordingRecoveryAssessment.Finding] = []
        var presented: Double = 0
        var available: Double = 0

        for segment in index.segments {
            let declared = segment.durationSeconds
            let measured = probesByPath[segment.screenRelativePath]?.measuredSeconds
            presented += declared ?? 0
            available += measured ?? declared ?? 0

            if declared == nil, let measured, measured >= tolerance {
                findings.append(
                    .unindexedScreenSegment(index: segment.index, seconds: measured)
                )
            }
        }

        // One file can be declared under more than one role, because system
        // audio is muxed into the screen video. Report the absent file once.
        var reportedMissingPaths: Set<String> = []
        for asset in declaredAssets {
            guard let probe = probesByPath[asset.relativePath] else { continue }
            guard probe.measuredSeconds == nil else { continue }
            guard reportedMissingPaths.insert(asset.relativePath).inserted else { continue }
            findings.append(
                .missingDeclaredAsset(
                    relativePath: asset.relativePath,
                    role: asset.role
                )
            )
        }

        // A side track is only compared against the screen time that actually
        // exists. Comparing against the presented total would report every
        // unindexed segment twice, once as lost picture and once as drift.
        if available > 0 {
            for probe in probes where Self.isSideTrack(probe.role) {
                guard let seconds = probe.measuredSeconds else { continue }
                let excess = seconds - available
                guard excess >= sideTrackAbsoluteThreshold,
                      excess / available >= sideTrackRelativeThreshold
                else { continue }
                findings.append(
                    .sideTrackOutlivesScreen(
                        role: probe.role,
                        relativePath: probe.relativePath,
                        screenSeconds: available,
                        trackSeconds: seconds
                    )
                )
            }
        }

        return RecordingRecoveryAssessment(
            findings: findings,
            presentedScreenSeconds: presented,
            availableScreenSeconds: available
        )
    }

    /// Only the tracks the recording actually presents. A per-segment file is
    /// an input that assembly clips to its own segment's screen duration, so
    /// comparing it against the whole recording reports a rebuild that already
    /// succeeded as though it were still broken.
    static func isSideTrack(_ role: TraceAsset.Role) -> Bool {
        switch role {
        case .microphone, .camera, .systemAudio:
            true
        default:
            false
        }
    }
}
