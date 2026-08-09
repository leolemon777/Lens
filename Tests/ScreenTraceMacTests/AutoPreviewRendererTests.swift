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

    @MainActor
    func testSyntheticPresenterCameraTrackIsCompositedIntoAutomaticPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTracePresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        let outputURL = directory.appendingPathComponent("presenter.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: screenURL,
            frameCount: 30,
            framesPerSecond: 24
        )
        try await SyntheticVideoFactory.makeVideo(
            at: cameraURL,
            frameCount: 30,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.presenterCamera = AutoEditPlan.PresenterCamera(
            isEnabled: true,
            shape: .circle,
            anchor: .bottomTrailing,
            size: 0.26,
            margin: 0.04,
            isMirrored: true,
            shadowOpacity: 0.35
        )
        let renderer = AutoPreviewRenderer()

        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertNil(renderer.lastPresenterCameraError)
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertGreaterThan(duration, 1.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let frame = try await generator.image(
            at: CMTime(seconds: 0.5, preferredTimescale: 600)
        ).image
        let bitmap = NSBitmapImageRep(cgImage: frame)
        var greenPixels = 0
        var strongestGreen: (score: CGFloat, color: NSColor) = (-1, .black)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let score = color.greenComponent - max(color.redComponent, color.blueComponent)
                if color.greenComponent > 0.85, score > 0.55 {
                    greenPixels += 1
                }
                if score > strongestGreen.score {
                    strongestGreen = (score, color)
                }
            }
        }
        XCTAssertGreaterThan(
            greenPixels,
            250,
            "strongest=\(strongestGreen.color), score=\(strongestGreen.score)"
        )
    }

    @MainActor
    func testPresenterCameraPreviewPreservesScreenAudioTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTracePresenterAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoOnlyURL = directory.appendingPathComponent("video-only.mp4")
        let narrationURL = directory.appendingPathComponent("tone.caf")
        let screenURL = directory.appendingPathComponent("screen-with-audio.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        let outputURL = directory.appendingPathComponent("presenter-with-audio.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: videoOnlyURL,
            frameCount: 30,
            framesPerSecond: 24
        )
        try makeTone(at: narrationURL, frameCount: 60_000)
        try await mux(videoURL: videoOnlyURL, audioURL: narrationURL, outputURL: screenURL)
        try await SyntheticVideoFactory.makeVideo(
            at: cameraURL,
            frameCount: 30,
            framesPerSecond: 24,
            style: .greenCamera
        )
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = true
        let renderer = AutoPreviewRenderer()

        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertNil(renderer.lastPresenterCameraError)
        let output = AVURLAsset(url: outputURL)
        let audioTracks = try await output.loadTracks(withMediaType: .audio)
        let duration = try await output.load(.duration).seconds
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertGreaterThan(duration, 1.1)
    }

    @MainActor
    func testBrokenCameraTrackFallsBackToScreenPreviewWithoutLosingOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTracePresenterFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("broken-camera.mov")
        let outputURL = directory.appendingPathComponent("fallback.mp4")
        try await SyntheticVideoFactory.makeVideo(
            at: screenURL,
            frameCount: 12,
            framesPerSecond: 24
        )
        try Data([1, 2, 3, 4]).write(to: cameraURL)
        var plan = AutoEditPlan()
        plan.presenterCamera?.isEnabled = true
        let renderer = AutoPreviewRenderer()

        _ = try await renderer.render(
            inputURL: screenURL,
            cameraURL: cameraURL,
            outputURL: outputURL,
            plan: plan
        )

        XCTAssertNotNil(renderer.lastPresenterCameraError)
        let output = AVURLAsset(url: outputURL)
        let videoTracks = try await output.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                as? NSNumber)?.int64Value ?? 0,
            1_000
        )
    }

    @MainActor
    private func mux(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        let outputVideo = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let outputAudio = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try outputVideo.insertTimeRange(
            CMTimeRange(start: videoRange.start, duration: duration),
            of: videoTrack,
            at: .zero
        )
        outputVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        try outputAudio.insertTimeRange(
            CMTimeRange(start: audioRange.start, duration: duration),
            of: audioTrack,
            at: .zero
        )
        let exporter = try XCTUnwrap(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ))
        try await exporter.export(to: outputURL, as: .mp4)
    }

    private func makeTone(at url: URL, frameCount: AVAudioFrameCount) throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = sin(Float(index) * 0.035) * 0.15
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }
}

enum SyntheticVideoStyle {
    case quadrants
    case greenCamera
}

enum SyntheticVideoFactory {
    static func makeVideo(
        at url: URL,
        frameCount: Int,
        framesPerSecond: Int,
        style: SyntheticVideoStyle = .quadrants
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
            let pixelBuffer = try makePixelBuffer(
                width: width,
                height: height,
                frame: index,
                style: style
            )
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

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        frame: Int,
        style: SyntheticVideoStyle
    ) throws -> CVPixelBuffer {
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
                switch style {
                case .quadrants:
                    let right = x >= width / 2
                    let bottom = y >= height / 2
                    row[offset] = UInt8(right ? 210 : 55)                       // B
                    row[offset + 1] = UInt8(bottom ? 190 : 70)                 // G
                    row[offset + 2] = UInt8((frame * 5 + (right ? 90 : 220)) % 255) // R
                case .greenCamera:
                    row[offset] = 25
                    row[offset + 1] = 235
                    row[offset + 2] = 20
                }
                row[offset + 3] = 255
            }
        }
        return buffer
    }
}
