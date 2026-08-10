import AVFoundation
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

final class VideoExportProfileTests: XCTestCase {
    func testMissingLegacySettingKeepsSourceQuality() {
        let profile = VideoExportProfile(nil)

        XCTAssertEqual(profile.preset, .source)
        XCTAssertEqual(profile.assetExportPresetName, AVAssetExportPresetHighestQuality)
        XCTAssertNil(profile.maximumFramesPerSecond)
        XCTAssertEqual(
            profile.limitedFrameDuration(CMTime(value: 1, timescale: 60)),
            CMTime(value: 1, timescale: 60)
        )
    }

    func testBalancedAndCompactCapFrameRateWithoutIncreasingSlowSources() {
        let balanced = VideoExportProfile(.init(preset: .balanced))
        let compact = VideoExportProfile(.init(preset: .compact))

        XCTAssertEqual(
            balanced.limitedFrameDuration(CMTime(value: 1, timescale: 60)).seconds,
            1.0 / 30,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            compact.limitedFrameDuration(CMTime(value: 1, timescale: 60)).seconds,
            1.0 / 24,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            compact.limitedFrameDuration(CMTime(value: 1, timescale: 12)).seconds,
            1.0 / 12,
            accuracy: 0.000_001
        )
        XCTAssertEqual(compact.assetExportPresetName, AVAssetExportPresetMediumQuality)
        XCTAssertLessThan(compact.presenterBitRateScale, balanced.presenterBitRateScale)
    }
}
