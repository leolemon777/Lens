@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CoreVideo
import Foundation
import LensCore

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
        export: AutoEditPlan.Export? = nil,
        timeline: VideoEditTimeline? = nil,
        cameraKeyframes: [AutoEditPlan.CameraKeyframe] = [],
        captions: AutoEditPlan.Captions? = nil,
        captionCues: [CaptionCue]? = nil
    ) async throws -> URL {
        let exportProfile = VideoExportProfile(export)
        let screenAsset = AVURLAsset(url: screenURL)
        let transitionedCameraURL: URL? = if timeline?.hasActiveTransitions == true {
            outputURL.deletingLastPathComponent().appendingPathComponent(
                ".presenter-transitions-\(UUID().uuidString).mp4"
            )
        } else {
            nil
        }
        let cameraAsset: AVAsset
        if let timeline, let transitionedCameraURL {
            _ = try await VideoTimelineCompositionBuilder().export(
                inputURL: cameraURL,
                timeline: timeline,
                outputURL: transitionedCameraURL,
                includesVideo: true,
                includesAudio: false,
                requiresVideo: true
            )
            cameraAsset = AVURLAsset(url: transitionedCameraURL)
        } else if let timeline {
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
        defer {
            if let transitionedCameraURL {
                try? FileManager.default.removeItem(at: transitionedCameraURL)
            }
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

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let videoOnlyURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".presenter-video-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: videoOnlyURL) }
        let writer = try AVAssetWriter(outputURL: videoOnlyURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(outputSize.width.rounded()),
                AVVideoHeightKey: Int(outputSize.height.rounded()),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.videoBitRate(
                        for: outputSize,
                        scale: exportProfile.presenterBitRateScale
                    ),
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
            let outputTime = max(time.seconds.isFinite ? time.seconds : 0, 0)
            let sourceTime = timeline?.position(atOutputTime: outputTime)?.sourceTimeSeconds
                ?? outputTime
            let captionAmount = captionCues.map {
                CaptionCuePlanner.avoidanceAmount(at: outputTime, in: $0)
            } ?? (captions == nil ? 0 : 1)
            let activeCaptions = captionAmount > 0.001 ? captions : nil
            let frameState = PresenterCameraPlacementPlanner.state(
                atSourceTime: sourceTime,
                layout: layout,
                cameraKeyframes: cameraKeyframes,
                captions: activeCaptions,
                captionAvoidanceAmount: captionAmount,
                canvasAspectRatio: outputExtent.width / max(outputExtent.height, 1)
            )
            let composed = Self.compose(
                screen: screenImage,
                camera: cameraImage,
                layout: layout,
                outputExtent: outputExtent,
                frameState: frameState
            )
            try await Self.waitUntilReady(videoInput, writer: writer)
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
                screenReader.error?.localizedDescription ?? "屏幕媒体读取失败"
            )
        }
        if cameraReader.status == .failed {
            throw PresenterCameraRendererError.mediaWriteFailed(
                cameraReader.error?.localizedDescription ?? "摄像头视频读取失败"
            )
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PresenterCameraRendererError.mediaWriteFailed(
                writer.error?.localizedDescription ?? "输出没有完成"
            )
        }
        if let audioTrack {
            return try await Self.attachAudio(
                from: audioTrack,
                toVideoAt: videoOnlyURL,
                outputURL: outputURL
            )
        }
        try FileManager.default.moveItem(at: videoOnlyURL, to: outputURL)
        return outputURL
    }

    nonisolated static func compose(
        screen: CIImage,
        camera: CIImage?,
        layout: AutoEditPlan.PresenterCamera,
        outputExtent: CGRect,
        frameState: PresenterCameraFrameState? = nil
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

        let state = frameState ?? PresenterCameraPlacementPlanner.state(
            atSourceTime: 0,
            layout: layout,
            canvasAspectRatio: outputExtent.width / max(outputExtent.height, 1)
        )
        let heightRatio: CGFloat = layout.shape == .circle ? 1 : 9 / 16
        let safeMargin = min(max(layout.margin, 0), 0.20)
        let requestedWidth = outputExtent.width * min(max(state.size, 0.001), 0.45)
        let maximumWidthByHeight = outputExtent.height * (1 - safeMargin * 2)
            / heightRatio
        let width = min(requestedWidth, maximumWidthByHeight)
        let height = width * heightRatio
        let requestedCenter = CGPoint(
            x: outputExtent.minX + CGFloat(state.center.x) * outputExtent.width,
            y: outputExtent.minY + CGFloat(1 - state.center.y) * outputExtent.height
        )
        let center = CGPoint(
            x: min(max(requestedCenter.x, outputExtent.minX + width / 2), outputExtent.maxX - width / 2),
            y: min(max(requestedCenter.y, outputExtent.minY + height / 2), outputExtent.maxY - height / 2)
        )
        let origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
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

    private nonisolated static func videoBitRate(
        for size: CGSize,
        scale: Double
    ) -> Int {
        let pixels = max(size.width * size.height, 1)
        let safeScale = min(max(scale.isFinite ? scale : 1, 0.2), 1)
        return Int(min(max(pixels * 8 * safeScale, 1_500_000), 28_000_000))
    }

    private nonisolated static func attachAudio(
        from audioTrack: AVAssetTrack,
        toVideoAt videoURL: URL,
        outputURL: URL
    ) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw PresenterCameraRendererError.missingScreenTrack
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let composition = AVMutableComposition()
        guard let outputVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PresenterCameraRendererError.writerUnavailable
        }
        try outputVideo.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        outputVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        let audioDuration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        if CMTimeCompare(audioDuration, .zero) > 0 {
            guard let outputAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw PresenterCameraRendererError.writerUnavailable
            }
            try outputAudio.insertTimeRange(
                CMTimeRange(start: audioRange.start, duration: audioDuration),
                of: audioTrack,
                at: .zero
            )
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw PresenterCameraRendererError.writerUnavailable
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .mp4)
        return outputURL
    }

    private nonisolated static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw PresenterCameraRendererError.mediaWriteFailed(
                    writer.error?.localizedDescription ?? "输出写入器已停止"
                )
            }
            guard clock.now < deadline else {
                throw PresenterCameraRendererError.mediaWriteFailed("输出写入器长时间无响应")
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
