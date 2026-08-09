import AVFoundation
import AppKit
import CoreVideo
import Foundation
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

final class AutoPreviewRendererTests: XCTestCase {
    @MainActor
    func testSyntheticVideoRendersNaturalCameraAndCursorPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTraceRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.mp4")
        let outputURL = directory.appendingPathComponent("output.mp4")
        try await SyntheticVideoFactory.makeVideo(at: inputURL, frameCount: 36, framesPerSecond: 24)

        var plan = AutoEditPlan()
        plan.camera.keyframes = [
            AutoEditPlan.CameraKeyframe(
                time: 0,
                scale: 1,
                center: TracePoint(x: 0.5, y: 0.5),
                easing: "linear",
                reason: .baseline
            ),
            AutoEditPlan.CameraKeyframe(
                time: 0.6,
                scale: 1.5,
                center: TracePoint(x: 0.72, y: 0.35),
                easing: "spring-smooth",
                reason: .clickFocus
            ),
            AutoEditPlan.CameraKeyframe(
                time: 1.3,
                scale: 1,
                center: TracePoint(x: 0.5, y: 0.5),
                easing: "spring-gentle",
                reason: .returnToOverview
            )
        ]
        plan.cursor.keyframes = [
            AutoEditPlan.CursorKeyframe(time: 0, position: TracePoint(x: 0.2, y: 0.7)),
            AutoEditPlan.CursorKeyframe(time: 0.8, position: TracePoint(x: 0.72, y: 0.35))
        ]
        plan.interaction?.clickPulses = [
            AutoEditPlan.ClickPulse(
                time: 0.55,
                position: TracePoint(x: 0.72, y: 0.35),
                button: .left
            )
        ]

        let renderedURL = try await AutoPreviewRenderer().render(
            inputURL: inputURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertEqual(renderedURL, outputURL)
        let fileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber
        XCTAssertGreaterThan(fileSize?.int64Value ?? 0, 1_000)
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertGreaterThan(duration, 1.3)
        XCTAssertLessThan(duration, 1.7)

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        let renderedFrame = try await imageGenerator.image(at: CMTime(seconds: 0.7, preferredTimescale: 600)).image
        XCTAssertEqual(renderedFrame.width, 640)
        XCTAssertEqual(renderedFrame.height, 360)
        let bitmap = NSBitmapImageRep(cgImage: renderedFrame)
        let cornerColor = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
        XCTAssertTrue((0.72...0.92).contains(cornerColor.redComponent), "\(cornerColor)")
        XCTAssertTrue((0.72...0.91).contains(cornerColor.greenComponent), "\(cornerColor)")
        XCTAssertTrue((0.68...0.90).contains(cornerColor.blueComponent), "\(cornerColor)")
    }
}

private enum SyntheticVideoFactory {
    static func makeVideo(
        at url: URL,
        frameCount: Int,
        framesPerSecond: Int
    ) async throws {
        let width = 640
        let height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw NSError(domain: "ScreenTraceTests", code: 1)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ScreenTraceTests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let pixelBuffer = try makePixelBuffer(width: width, height: height, frame: index)
            let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? NSError(domain: "ScreenTraceTests", code: 3)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "ScreenTraceTests", code: 4)
        }
    }

    private static func makePixelBuffer(width: Int, height: Int, frame: Int) throws -> CVPixelBuffer {
        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &optionalBuffer
        )
        guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw NSError(domain: "ScreenTraceTests", code: Int(status))
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "ScreenTraceTests", code: 5)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                let right = x >= width / 2
                let bottom = y >= height / 2
                row[offset] = UInt8(right ? 210 : 55)                       // B
                row[offset + 1] = UInt8(bottom ? 190 : 70)                 // G
                row[offset + 2] = UInt8((frame * 5 + (right ? 90 : 220)) % 255) // R
                row[offset + 3] = 255
            }
        }
        return buffer
    }
}
