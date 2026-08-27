import AVFoundation
import CoreGraphics
import CoreVideo
import XCTest
@testable import LensCore
@testable import LensMac

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
        XCTAssertEqual(compact.assetExportPresetName, AVAssetExportPresetHEVCHighestQuality)
        XCTAssertLessThan(compact.presenterBitRateScale, balanced.presenterBitRateScale)
    }

    /// The compact profile once used a device-adaptive quality preset, which
    /// rescaled a 1920x1080 screen recording down to 568x320 even with an
    /// explicit full-size renderSize. Legibility is the whole point of a screen
    /// recorder, so every delivery profile must preserve source dimensions.
    func testEveryProfileKeepsSourceResolution() async throws {
        let sourceURL = try Self.makeSourceClip(width: 1_920, height: 1_080)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        for preset in AutoEditPlan.Export.Preset.allCases {
            let profile = VideoExportProfile(.init(preset: preset))
            let size = try await Self.exportedDimensions(
                of: sourceURL,
                using: profile,
                renderSize: CGSize(width: 1_920, height: 1_080)
            )
            XCTAssertEqual(
                size.width, 1_920, accuracy: 1,
                "\(preset.rawValue) 改变了输出宽度"
            )
            XCTAssertEqual(
                size.height, 1_080, accuracy: 1,
                "\(preset.rawValue) 改变了输出高度"
            )
        }
    }

    // MARK: - Helpers

    private static func makeSourceClip(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-profile-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { continue }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context?.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
            context?.fill(CGRect(x: frame * 40, y: 400, width: 300, height: 120))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            while !input.isReadyForMoreMediaData { usleep(500) }
            adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
            )
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        return url
    }

    private static func exportedDimensions(
        of sourceURL: URL,
        using profile: VideoExportProfile,
        renderSize: CGSize
    ) async throws -> CGSize {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-profile-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let asset = AVURLAsset(url: sourceURL)
        let exporter = try XCTUnwrap(AVAssetExportSession(
            asset: asset,
            presetName: profile.assetExportPresetName
        ))
        let composition = try await AVMutableVideoComposition
            .videoComposition(withPropertiesOf: asset)
        composition.renderSize = renderSize
        exporter.videoComposition = composition
        try await exporter.export(to: outputURL, as: .mp4)
        let output = AVURLAsset(url: outputURL)
        let tracks = try await output.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        return try await track.load(.naturalSize)
    }
}
