@preconcurrency import AVFoundation
import CoreMedia
import LensCore

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
            // A device-adaptive quality preset is not a bitrate knob: it rescales
            // a 1920x1080 source down to 568x320 even when the video composition
            // carries an explicit full-size renderSize. Text legibility is the
            // only thing a screen recording has to preserve, so trade codec
            // efficiency for size instead of pixels. HEVC lands roughly 35%
            // smaller than H.264 at the same dimensions, and the frame-rate cap
            // supplies the rest of the reduction.
            assetExportPresetName = AVAssetExportPresetHEVCHighestQuality
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
