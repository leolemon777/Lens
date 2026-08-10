@preconcurrency import AVFoundation
import CoreMedia
import ScreenTraceCore

/// Concrete macOS encoding behavior for the portable export preference.
/// A missing value means a project predates export presets and therefore keeps
/// its historical source-quality behavior.
struct VideoExportProfile: Equatable, Sendable {
    let preset: AutoEditPlan.Export.Preset
    let assetExportPresetName: String
    let maximumFramesPerSecond: Double?
    let presenterBitRateScale: Double

    init(_ configuration: AutoEditPlan.Export?) {
        preset = configuration?.preset ?? .source
        switch preset {
        case .source:
            assetExportPresetName = AVAssetExportPresetHighestQuality
            maximumFramesPerSecond = nil
            presenterBitRateScale = 1
        case .balanced:
            assetExportPresetName = AVAssetExportPresetHighestQuality
            maximumFramesPerSecond = 30
            presenterBitRateScale = 0.72
        case .compact:
            assetExportPresetName = AVAssetExportPresetMediumQuality
            maximumFramesPerSecond = 24
            presenterBitRateScale = 0.38
        }
    }

    func limitedFrameDuration(_ current: CMTime) -> CMTime {
        guard let maximumFramesPerSecond else { return current }
        let minimumDuration = 1 / maximumFramesPerSecond
        let currentSeconds = current.seconds
        let duration = currentSeconds.isFinite && currentSeconds > 0
            ? max(currentSeconds, minimumDuration)
            : minimumDuration
        return CMTime(seconds: duration, preferredTimescale: 60_000)
    }
}
