@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation
import ScreenTraceCore

enum PresenterCameraRendererError: LocalizedError {
    case missingScreenTrack
    case missingCameraTrack
    case readerUnavailable
    case writerUnavailable
    case pixelBufferUnavailable
    case mediaWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingScreenTrack: "自动预览缺少屏幕视频轨。"
        case .missingCameraTrack: "摄像头原始文件缺少视频轨。"
        case .readerUnavailable: "无法读取自动预览所需的媒体轨道。"
        case .writerUnavailable: "无法创建摄像头画中画输出。"
        case .pixelBufferUnavailable: "无法分配画中画视频帧。"
        case let .mediaWriteFailed(message): "摄像头画中画写入失败：\(message)"
        }
    }
}

final class PresenterCameraRenderer: @unchecked Sendable {
    func render(
        screenURL: URL,
        cameraURL: URL,
        outputURL: URL,
        layout: AutoEditPlan.PresenterCamera,
        timeline: VideoEditTimeline? = nil
    ) async throws -> URL {
        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset: AVAsset
        if let timeline {
            cameraAsset = try await VideoTimelineCompositionBuilder().build(
                inputURL: cameraURL,
                timeline: timeline,
                includesVideo: true,
                includesAudio: false,
                requiresVideo: true
            )
        } else {
            cameraAsset = AVURLAsset(url: cameraURL)
        }
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw PresenterCameraRendererError.missingScreenTrack
        }
        guard let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first else {
            throw PresenterCameraRendererError.missingCameraTrack
        }

        let screenTransform = try await screenTrack.load(.preferredTransform)
        let cameraTransform = try await cameraTrack.load(.preferredTransform)
        let screenNaturalSize = try await screenTrack.load(.naturalSize)
        let outputSize = Self.orientedSize(
            naturalSize: screenNaturalSize,
            transform: screenTransform
        )
        guard outputSize.width >= 2, outputSize.height >= 2 else {
            throw PresenterCameraRendererError.missingScreenTrack
        }

        let screenReader = try AVAssetReader(asset: screenAsset)
        let cameraReader = try AVAssetReader(asset: cameraAsset)
        let pixelSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let screenOutput = AVAssetReaderTrackOutput(track: screenTrack, outputSettings: pixelSettings)
        let cameraOutput = AVAssetReaderTrackOutput(track: cameraTrack, outputSettings: pixelSettings)
        screenOutput.alwaysCopiesSampleData = false
        cameraOutput.alwaysCopiesSampleData = false
        guard screenReader.canAdd(screenOutput), cameraReader.canAdd(cameraOutput) else {
            throw PresenterCameraRendererError.readerUnavailable
        }
        screenReader.add(screenOutput)
        cameraReader.add(cameraOutput)

        let audioTrack = try await screenAsset.loadTracks(withMediaType: .audio).first
        let audioOutput: AVAssetReaderTrackOutput?
        let audioInput: AVAssetWriterInput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            guard screenReader.canAdd(output) else {
                throw PresenterCameraRendererError.readerUnavailable
            }
            screenReader.add(output)
            audioOutput = output
            let formatDescription = try await audioTrack.load(.formatDescriptions).first
            audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescription
            )
        } else {
            audioOutput = nil
            audioInput = nil
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width.rounded()),
                AVVideoHeightKey: Int(outputSize.height.rounded()),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.videoBitRate(for: outputSize),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width.rounded()),
                kCVPixelBufferHeightKey as String: Int(outputSize.height.rounded()),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw PresenterCameraRendererError.writerUnavailable
        }
        writer.add(videoInput)
        if let audioInput {
            guard writer.canAdd(audioInput) else {
                throw PresenterCameraRendererError.writerUnavailable
            }
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
        }

        guard writer.startWriting() else {
            throw PresenterCameraRendererError.mediaWriteFailed(
                writer.error?.localizedDescription ?? "输出写入器无法启动"
            )
        }
        defer {
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }
        guard screenReader.startReading(), cameraReader.startReading() else {
            throw PresenterCameraRendererError.readerUnavailable
        }
        writer.startSession(atSourceTime: .zero)
        defer {
            screenReader.cancelReading()
            cameraReader.cancelReading()
        }

        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])
        let outputExtent = CGRect(origin: .zero, size: outputSize)
        let cameraDuration = try await cameraAsset.load(.duration).seconds
        var nextCameraSample = cameraOutput.copyNextSampleBuffer()
        var currentCameraBuffer: CVPixelBuffer?

        while let screenSample = screenOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(screenSample)
            while let candidate = nextCameraSample,
                  CMSampleBufferGetPresentationTimeStamp(candidate) <= time {
                currentCameraBuffer = CMSampleBufferGetImageBuffer(candidate)
                nextCameraSample = cameraOutput.copyNextSampleBuffer()
            }
            guard let screenBuffer = CMSampleBufferGetImageBuffer(screenSample) else { continue }
            let screenImage = Self.orient(
                CIImage(cvPixelBuffer: screenBuffer),
                transform: screenTransform,
                outputSize: outputSize
            )
            let cameraImage: CIImage? = {
                guard time.seconds <= cameraDuration + 0.15,
                      let currentCameraBuffer else { return nil }
                return Self.normalizeOrigin(
                    CIImage(cvPixelBuffer: currentCameraBuffer)
                        .transformed(by: cameraTransform)
                )
            }()
            let composed = Self.compose(
                screen: screenImage,
                camera: cameraImage,
                layout: layout,
                outputExtent: outputExtent
            )
            try await Self.waitUntilReady(videoInput)
            guard let pool = adaptor.pixelBufferPool else {
                throw PresenterCameraRendererError.pixelBufferUnavailable
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let outputBuffer = optionalBuffer else {
                throw PresenterCameraRendererError.pixelBufferUnavailable
            }
            context.render(
                composed,
                to: outputBuffer,
                bounds: outputExtent,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
            guard adaptor.append(outputBuffer, withPresentationTime: time) else {
                throw PresenterCameraRendererError.mediaWriteFailed(
                    writer.error?.localizedDescription ?? "视频帧写入被拒绝"
                )
            }
        }
        videoInput.markAsFinished()
        if screenReader.status == .failed {
            throw PresenterCameraRendererError.mediaWriteFailed(
                screenReader.error?.localizedDescription ?? "屏幕视频读取失败"
            )
        }
        if cameraReader.status == .failed {
            throw PresenterCameraRendererError.mediaWriteFailed(
                cameraReader.error?.localizedDescription ?? "摄像头视频读取失败"
            )
        }

        if let audioInput, let audioOutput {
            while let sample = audioOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try await Self.waitUntilReady(audioInput)
                guard audioInput.append(sample) else {
                    throw PresenterCameraRendererError.mediaWriteFailed(
                        writer.error?.localizedDescription ?? "系统声音写入被拒绝"
                    )
                }
            }
            audioInput.markAsFinished()
        }
        if screenReader.status == .failed {
            throw PresenterCameraRendererError.mediaWriteFailed(
                screenReader.error?.localizedDescription ?? "屏幕音频读取失败"
            )
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PresenterCameraRendererError.mediaWriteFailed(
                writer.error?.localizedDescription ?? "输出没有完成"
            )
        }
        return outputURL
    }

    nonisolated static func compose(
        screen: CIImage,
        camera: CIImage?,
        layout: AutoEditPlan.PresenterCamera,
        outputExtent: CGRect
    ) -> CIImage {
        let screen = screen.cropped(to: outputExtent)
        guard layout.isEnabled, var camera else { return screen }
        camera = normalizeOrigin(camera)
        if layout.isMirrored {
            let width = camera.extent.width
            camera = camera
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: width, y: 0))
        }

        let width = outputExtent.width * min(max(layout.size, 0.08), 0.45)
        let height: CGFloat = switch layout.shape {
        case .circle: width
        case .roundedRectangle: width * 9 / 16
        }
        let marginX = outputExtent.width * min(max(layout.margin, 0), 0.20)
        let marginY = outputExtent.height * min(max(layout.margin, 0), 0.20)
        let origin: CGPoint = switch layout.anchor {
        case .topLeading:
            CGPoint(x: marginX, y: outputExtent.height - marginY - height)
        case .topTrailing:
            CGPoint(x: outputExtent.width - marginX - width, y: outputExtent.height - marginY - height)
        case .bottomLeading:
            CGPoint(x: marginX, y: marginY)
        case .bottomTrailing:
            CGPoint(x: outputExtent.width - marginX - width, y: marginY)
        }
        let target = CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
        let fillScale = max(
            target.width / max(camera.extent.width, 1),
            target.height / max(camera.extent.height, 1)
        )
        camera = camera.transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
        camera = camera.transformed(by: CGAffineTransform(
            translationX: target.midX - camera.extent.midX,
            y: target.midY - camera.extent.midY
        )).cropped(to: target)

        let radius: CGFloat = switch layout.shape {
        case .circle: target.width / 2
        case .roundedRectangle:
            min(target.width, target.height) * min(max(layout.cornerRadius, 0), 0.5)
        }
        let maskFilter = CIFilter.roundedRectangleGenerator()
        maskFilter.extent = target
        maskFilter.radius = Float(radius)
        maskFilter.color = .white
        let mask = (maskFilter.outputImage ?? CIImage(color: .white).cropped(to: target))
            .cropped(to: outputExtent)
        let clear = CIImage(color: .clear).cropped(to: outputExtent)
        let clippedCamera = camera.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ]
        ).cropped(to: outputExtent)

        let shadowColor = CIImage(color: CIColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: min(max(layout.shadowOpacity, 0), 1)
        )).cropped(to: outputExtent)
        let shadowShape = shadowColor.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ]
        )
        let shadow = shadowShape
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: max(2, min(target.width, target.height) * 0.08)]
            )
            .transformed(by: CGAffineTransform(translationX: 0, y: -outputExtent.height * 0.008))
            .cropped(to: outputExtent)
        return clippedCamera
            .composited(over: shadow.composited(over: screen))
            .cropped(to: outputExtent)
    }

    private nonisolated static func orient(
        _ image: CIImage,
        transform: CGAffineTransform,
        outputSize: CGSize
    ) -> CIImage {
        var oriented = normalizeOrigin(image.transformed(by: transform))
        let scaleX = outputSize.width / max(oriented.extent.width, 1)
        let scaleY = outputSize.height / max(oriented.extent.height, 1)
        oriented = oriented.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return oriented.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private nonisolated static func normalizeOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
    }

    private nonisolated static func orientedSize(
        naturalSize: CGSize,
        transform: CGAffineTransform
    ) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        return CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
    }

    private nonisolated static func videoBitRate(for size: CGSize) -> Int {
        let pixels = max(size.width * size.height, 1)
        return Int(min(max(pixels * 8, 4_000_000), 28_000_000))
    }

    private nonisolated static func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
