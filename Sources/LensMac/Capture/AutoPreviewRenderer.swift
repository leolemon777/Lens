import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import LensCore

enum AutoPreviewRendererError: LocalizedError {
    case exportSessionUnavailable
    case cursorImageUnavailable

    var errorDescription: String? {
        switch self {
        case .exportSessionUnavailable: "无法创建自动成片导出任务。"
        case .cursorImageUnavailable: "无法读取系统光标图像。"
        }
    }
}

private struct CursorRenderAsset: @unchecked Sendable {
    let image: CIImage
    /// Normalized in AppKit's top-left coordinate system.
    let hotSpot: CGPoint
    let relativeWidth: CGFloat
}

private struct CursorRenderAssets: @unchecked Sendable {
    let system: [PointerCursorShape: CursorRenderAsset]
    let highContrast: CursorRenderAsset
    let minimalDot: CursorRenderAsset

    var arrow: CursorRenderAsset {
        system[.arrow] ?? highContrast
    }
}

@MainActor
final class AutoPreviewRenderer {
    private(set) var lastPresenterCameraError: Error?
    private var cachedCursorAssets: CursorRenderAssets?
    private var cachedClickRingImage: CIImage?

    /// Source-pixel cursor size shared by final rendering and the live editor.
    /// Retina captures are commonly 2560–3840 px wide; the previous 1.2% rule
    /// collapsed to a barely visible 8–16 px pointer after normal playback
    /// downscaling. This baseline remains user-scalable while preserving a
    /// clearly readable default at 1080p delivery sizes.
    nonisolated static func baseCursorWidth(sourcePixelWidth: CGFloat) -> CGFloat {
        min(max(sourcePixelWidth * 0.021, 36), 104)
    }

    func render(
        inputURL: URL,
        cameraURL: URL? = nil,
        outputURL: URL,
        plan: AutoEditPlan,
        transcript: TranscriptDocument? = nil,
        mixedAudioURL: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        lastPresenterCameraError = nil
        let availableCameraURL = cameraURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        let activePresenter = plan.presenterCamera.flatMap { layout in
            layout.isEnabled && availableCameraURL != nil ? layout : nil
        }
        let presenterAvoidanceKeyframes = EffectTimeline.effectiveCameraKeyframes(
            for: plan.camera
        )
        let captionCues: [CaptionCue] = {
            guard let configuration = plan.captions,
                  configuration.isEnabled,
                  let transcript else { return [] }
            return CaptionCuePlanner.cues(
                transcript: transcript,
                configuration: configuration,
                timeline: plan.timeline
            )
        }()
        let captionRenderer: CaptionOverlayRenderer? = {
            guard let configuration = plan.captions,
                  configuration.isEnabled,
                  !captionCues.isEmpty else { return nil }
            return CaptionOverlayRenderer(
                cues: captionCues,
                configuration: configuration,
                presenter: activePresenter,
                cameraKeyframes: presenterAvoidanceKeyframes,
                timeline: plan.timeline
            )
        }()
        let videoAnnotationRenderer: VideoAnnotationRenderer? = {
            guard let annotations = plan.videoAnnotations,
                  !annotations.isEmpty else { return nil }
            return VideoAnnotationRenderer(annotations: annotations)
        }()
        let transitionedInputURL: URL? = if let timeline = plan.timeline,
                                           timeline.hasActiveTransitions {
            outputURL.deletingLastPathComponent().appendingPathComponent(
                ".timeline-transitions-\(UUID().uuidString).mp4"
            )
        } else {
            nil
        }
        if let transitionedInputURL, let timeline = plan.timeline {
            _ = try await VideoTimelineCompositionBuilder().export(
                inputURL: inputURL,
                timeline: timeline,
                outputURL: transitionedInputURL,
                includesVideo: true,
                includesAudio: true,
                requiresVideo: true
            )
        }
        defer {
            if let transitionedInputURL {
                try? FileManager.default.removeItem(at: transitionedInputURL)
            }
        }
        let effectsInputURL = transitionedInputURL ?? inputURL
        guard let presenter = activePresenter,
              let cameraURL = availableCameraURL else {
            return try await renderScreenEffects(
                inputURL: effectsInputURL,
                outputURL: outputURL,
                plan: plan,
                captionRenderer: captionRenderer,
                videoAnnotationRenderer: videoAnnotationRenderer,
                appliesTimeline: transitionedInputURL == nil,
                mixedAudioURL: mixedAudioURL,
                progress: progress
            )
        }

        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".screen-effects-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        // Presenter-camera compositing is a second full encode pass; split
        // the caller's 0...1 in half instead of each pass restarting at 0.
        _ = try await renderScreenEffects(
            inputURL: effectsInputURL,
            outputURL: temporaryURL,
            plan: plan,
            captionRenderer: captionRenderer,
            videoAnnotationRenderer: videoAnnotationRenderer,
            appliesTimeline: transitionedInputURL == nil,
            mixedAudioURL: mixedAudioURL,
            progress: progress.map { Self.scaledProgress($0, offset: 0, scale: 0.5) }
        )
        do {
            return try await PresenterCameraRenderer().render(
                screenURL: temporaryURL,
                cameraURL: cameraURL,
                outputURL: outputURL,
                layout: presenter,
                export: plan.export,
                timeline: plan.timeline,
                cameraKeyframes: presenterAvoidanceKeyframes,
                captions: captionRenderer == nil ? nil : plan.captions,
                captionCues: captionCues,
                mixedAudioURL: mixedAudioURL,
                progress: progress.map { Self.scaledProgress($0, offset: 0.5, scale: 0.5) }
            )
        } catch {
            lastPresenterCameraError = error
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            return outputURL
        }
    }

    /// Renders one decoded source frame through the same effect compositor used
    /// by the encoded preview. This is intentionally an internal diagnostic
    /// entry point: the post-render verifier toggles one effect at a time and
    /// checks whether `auto.mp4` resembles the enabled or disabled result.
    func renderDiagnosticFrame(
        sourceImage: CGImage,
        outputTime: Double,
        plan: AutoEditPlan,
        transcript: TranscriptDocument? = nil,
        hasPresenterCamera: Bool = false,
        cameraSampleInterval: Double = 1.0 / 60.0
    ) throws -> CGImage {
        let source = CIImage(cgImage: sourceImage)
        let annotationRenderer = plan.videoAnnotations.flatMap {
            $0.isEmpty ? nil : VideoAnnotationRenderer(annotations: $0)
        }
        let activePresenter = plan.presenterCamera.flatMap {
            $0.isEnabled && hasPresenterCamera ? $0 : nil
        }
        let captionRenderer: CaptionOverlayRenderer? = {
            guard let configuration = plan.captions,
                  configuration.isEnabled,
                  let transcript else { return nil }
            let cues = CaptionCuePlanner.cues(
                transcript: transcript,
                configuration: configuration,
                timeline: plan.timeline
            )
            guard !cues.isEmpty else { return nil }
            return CaptionOverlayRenderer(
                cues: cues,
                configuration: configuration,
                presenter: activePresenter,
                cameraKeyframes: EffectTimeline.effectiveCameraKeyframes(
                    for: plan.camera
                ),
                timeline: plan.timeline
            )
        }()
        let rendered = Self.renderFrame(
            source,
            time: outputTime,
            plan: plan,
            cursorAssets: try reusableCursorAssets(),
            clickRingImage: try reusableClickRingImage(),
            captionRenderer: captionRenderer,
            videoAnnotationRenderer: annotationRenderer,
            cameraSampleInterval: cameraSampleInterval
        ).cropped(to: CGRect(origin: .zero, size: source.extent.size))
        guard let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(
            rendered,
            from: rendered.extent
        ) else {
            throw AutoPreviewRendererError.exportSessionUnavailable
        }
        return image
    }

    private func renderScreenEffects(
        inputURL: URL,
        outputURL: URL,
        plan: AutoEditPlan,
        captionRenderer: CaptionOverlayRenderer?,
        videoAnnotationRenderer: VideoAnnotationRenderer?,
        appliesTimeline: Bool,
        mixedAudioURL: URL? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let sourceAsset: AVAsset
        if appliesTimeline, let timeline = plan.timeline {
            sourceAsset = try await VideoTimelineCompositionBuilder().build(
                inputURL: inputURL,
                timeline: timeline,
                includesVideo: true,
                includesAudio: true,
                requiresVideo: true
            )
        } else {
            sourceAsset = AVURLAsset(url: inputURL)
        }
        // A prepared audio sidecar replaces the source audio in the same
        // encode that applies the visual effects, so narration mixing costs
        // no second video generation. The wrap is a plain composition: the
        // filter compositor and frame-timing logic below treat it exactly
        // like the timeline composition they already handle.
        let asset: AVAsset = if let mixedAudioURL {
            try await Self.assetByReplacingAudio(
                of: sourceAsset,
                withAudioAt: mixedAudioURL
            )
        } else {
            sourceAsset
        }
        let cursorAssets = try reusableCursorAssets()
        let clickRingImage = try reusableClickRingImage()
        let exportProfile = VideoExportProfile(plan.export)
        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        let sourceFrameDuration: CMTime = if let sourceTrack = sourceVideoTracks.first,
                                            let frameDuration = try? await sourceTrack.load(
                                                .minFrameDuration
                                            ),
                                            frameDuration.isNumeric,
                                            frameDuration.seconds.isFinite,
                                            frameDuration.seconds > 0 {
            frameDuration
        } else if let sourceTrack = sourceVideoTracks.first,
                  let nominalFrameRate = try? await sourceTrack.load(.nominalFrameRate),
                  nominalFrameRate.isFinite,
                  nominalFrameRate > 0 {
            CMTime(
                seconds: 1 / Double(min(max(nominalFrameRate, 1), 120)),
                preferredTimescale: 60_000
            )
        } else {
            CMTime(value: 1, timescale: 30)
        }
        let cameraSampleInterval = sourceFrameDuration.seconds
        let orientedSourceSize: CGSize = await {
            guard let track = sourceVideoTracks.first else { return .zero }
            let naturalSize = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform))
                ?? CGAffineTransform.identity
            let oriented = naturalSize.applying(transform)
            return CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }()
        let deliverySize = Self.deliverySize(
            source: orientedSourceSize,
            aspectRatio: plan.export?.aspectRatio
        )
        let outputExtent = CGRect(origin: .zero, size: deliverySize)
        let composition = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AVMutableVideoComposition, Error>) in
            AVMutableVideoComposition.videoComposition(
                with: asset,
                applyingCIFiltersWithHandler: { request in
                let time = request.compositionTime.seconds
                let result = Self.renderFrame(
                    request.sourceImage,
                    time: time,
                    plan: plan,
                    cursorAssets: cursorAssets,
                    clickRingImage: clickRingImage,
                    captionRenderer: captionRenderer,
                    videoAnnotationRenderer: videoAnnotationRenderer,
                    cameraSampleInterval: cameraSampleInterval,
                    outputExtent: outputExtent
                )
                request.finish(with: result, context: nil)
                },
                completionHandler: { composition, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let composition {
                        continuation.resume(returning: composition)
                    } else {
                        continuation.resume(throwing: AutoPreviewRendererError.exportSessionUnavailable)
                    }
                }
            )
        }
        // Social reframe: the filter convenience constructor inherits the
        // source's natural size, so an explicit renderSize is how the delivery
        // aspect reaches the exported file.
        if composition.renderSize != deliverySize {
            composition.renderSize = deliverySize
        }
        // AVFoundation's filter convenience composition defaults to 30 FPS,
        // even when its source is a real 60 FPS capture. Derive timing from the
        // source track first, then apply only an explicitly selected delivery
        // cap. Otherwise every smart effect silently halves temporal fidelity.
        let limitedFrameDuration = exportProfile.limitedFrameDuration(sourceFrameDuration)
        if exportProfile.maximumFramesPerSecond == nil,
           let sourceVideoTrack = sourceVideoTracks.first {
            // H.264 High Profile capture can contain B-frame decode reordering.
            // Driving the filter compositor from a synthetic fixed duration
            // makes AVFoundation fall back to 30 FPS for those otherwise-valid
            // 60 FPS tracks. Source quality must follow the source track's
            // presentation timeline directly so every real 60 Hz sample reaches
            // time-dependent camera, cursor and click effects.
            composition.sourceTrackIDForFrameTiming = sourceVideoTrack.trackID
            composition.frameDuration = sourceFrameDuration
        } else if limitedFrameDuration != composition.frameDuration {
            composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
            composition.frameDuration = limitedFrameDuration
        }

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: exportProfile.assetExportPresetName
        ) else {
            throw AutoPreviewRendererError.exportSessionUnavailable
        }
        exporter.videoComposition = composition
        exporter.shouldOptimizeForNetworkUse = true
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await Self.runExport(exporter, to: outputURL, as: .mp4, progress: progress)
        return outputURL
    }

    /// Polls export progress via a concurrent child task and cancels it once
    /// the export call returns; `states` only stops on its own once the
    /// session reaches a terminal state, so an explicit teardown is needed
    /// whether or not the caller wants updates. Shared with
    /// `PresenterCameraRenderer`'s own passthrough remux export.
    nonisolated static func runExport(
        _ exporter: AVAssetExportSession,
        to outputURL: URL,
        as fileType: AVFileType,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let progress else {
            try await exporter.export(to: outputURL, as: fileType)
            return
        }
        // Concurrent progress polling alongside the export call is the
        // documented use of `states(updateInterval:)`; the session type
        // predates Sendable, so the capture is annotated rather than
        // provably checked by the compiler.
        nonisolated(unsafe) let exporter = exporter
        let progressTask = Task {
            for try await state in exporter.states(updateInterval: 0.1) {
                if case .exporting(let fraction) = state {
                    progress(fraction.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }
        try await exporter.export(to: outputURL, as: fileType)
        progress(1)
    }

    /// Rescales a sub-pass's own 0...1 progress into its slice of the
    /// overall 0...1 reported to the caller, so a second encode pass
    /// continues from where the first left off instead of restarting at 0.
    nonisolated static func scaledProgress(
        _ report: @escaping @Sendable (Double) -> Void,
        offset: Double,
        scale: Double
    ) -> @Sendable (Double) -> Void {
        { fraction in report(offset + fraction * scale) }
    }

    /// Combines the source's video with the sidecar's audio in one mutable
    /// composition. Full-range insertion preserves the (already timeline-
    /// mapped) presentation of both sides; the sidecar is authored against
    /// the same output duration the effects render produces.
    nonisolated private static func assetByReplacingAudio(
        of asset: AVAsset,
        withAudioAt audioURL: URL
    ) async throws -> AVAsset {
        let composition = AVMutableComposition()
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let outputVideo = composition.addMutableTrack(
                  withMediaType: .video,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw AutoPreviewRendererError.exportSessionUnavailable
        }
        let videoRange = try await sourceVideo.load(.timeRange)
        try outputVideo.insertTimeRange(videoRange, of: sourceVideo, at: .zero)
        outputVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
        // The sidecar asset must outlive the insertion below: a track whose
        // owning AVURLAsset was deallocated makes insertTimeRange fail with
        // AVFoundation -11800/-12780.
        let sidecarAsset = AVURLAsset(url: audioURL)
        if let sidecarAudio = try await sidecarAsset
            .loadTracks(withMediaType: .audio).first,
           let outputAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioRange = try await sidecarAudio.load(.timeRange)
            if audioRange.duration.isNumeric, audioRange.duration > .zero {
                try outputAudio.insertTimeRange(audioRange, of: sidecarAudio, at: .zero)
            }
        }
        return composition
    }

    private func cursorAsset(
        for cursor: NSCursor,
        relativeWidth: CGFloat = 1
    ) throws -> CursorRenderAsset {
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            let width = max(image.size.width, 1)
            let height = max(image.size.height, 1)
            return CursorRenderAsset(
                image: CIImage(cgImage: cgImage),
                hotSpot: CGPoint(
                    x: min(max(cursor.hotSpot.x / width, 0), 1),
                    y: min(max(cursor.hotSpot.y / height, 0), 1)
                ),
                relativeWidth: relativeWidth
            )
        }
        return CursorRenderAsset(
            image: try fallbackCursorImage(),
            hotSpot: CGPoint(x: 0.1, y: 4.0 / 48.0),
            relativeWidth: relativeWidth
        )
    }

    private func reusableCursorAssets() throws -> CursorRenderAssets {
        if let cachedCursorAssets { return cachedCursorAssets }
        let cursorMap: [(PointerCursorShape, NSCursor)] = [
            (.arrow, .arrow),
            (.pointingHand, .pointingHand),
            (.iBeam, .iBeam),
            (.verticalIBeam, .iBeamCursorForVerticalLayout),
            (.crosshair, .crosshair),
            (.openHand, .openHand),
            (.closedHand, .closedHand),
            (.horizontalResize, .columnResize),
            (.verticalResize, .rowResize),
            (.operationNotAllowed, .operationNotAllowed),
            (.dragCopy, .dragCopy),
            (.dragLink, .dragLink),
            (.contextualMenu, .contextualMenu),
            (.disappearingItem, .disappearingItem)
        ]
        let arrowWidth = max(NSCursor.arrow.image.size.width, 1)
        var system: [PointerCursorShape: CursorRenderAsset] = [:]
        for (shape, cursor) in cursorMap {
            system[shape] = try cursorAsset(
                for: cursor,
                relativeWidth: max(cursor.image.size.width, 1) / arrowWidth
            )
        }
        let assets = CursorRenderAssets(
            system: system,
            highContrast: CursorRenderAsset(
                image: try fallbackCursorImage(),
                hotSpot: CGPoint(x: 0.1, y: 4.0 / 48.0),
                relativeWidth: 1
            ),
            minimalDot: CursorRenderAsset(
                image: try dotCursorImage(),
                hotSpot: CGPoint(x: 0.5, y: 0.5),
                relativeWidth: 0.72
            )
        )
        cachedCursorAssets = assets
        return assets
    }

    private func reusableClickRingImage() throws -> CIImage {
        if let cachedClickRingImage { return cachedClickRingImage }
        let image = try clickRingImage()
        cachedClickRingImage = image
        return image
    }

    private func fallbackCursorImage() throws -> CIImage {
        let width = 40
        let height = 48
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AutoPreviewRendererError.cursorImageUnavailable
        }

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 4, y: 44))
        path.addLine(to: CGPoint(x: 4, y: 8))
        path.addLine(to: CGPoint(x: 13, y: 17))
        path.addLine(to: CGPoint(x: 20, y: 3))
        path.addLine(to: CGPoint(x: 26, y: 6))
        path.addLine(to: CGPoint(x: 19, y: 20))
        path.addLine(to: CGPoint(x: 33, y: 20))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(4)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        guard let cgImage = context.makeImage() else {
            throw AutoPreviewRendererError.cursorImageUnavailable
        }
        return CIImage(cgImage: cgImage)
    }

    private func dotCursorImage() throws -> CIImage {
        let size = 48
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AutoPreviewRendererError.cursorImageUnavailable
        }
        let outer = CGRect(x: 4, y: 4, width: 40, height: 40)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: outer)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: outer.insetBy(dx: 1.5, dy: 1.5))
        guard let cgImage = context.makeImage() else {
            throw AutoPreviewRendererError.cursorImageUnavailable
        }
        return CIImage(cgImage: cgImage)
    }

    private func clickRingImage() throws -> CIImage {
        let size = 72
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AutoPreviewRendererError.cursorImageUnavailable
        }
        let ringRect = CGRect(x: 6, y: 6, width: 60, height: 60)
        context.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.92).cgColor)
        context.setLineWidth(5)
        context.strokeEllipse(in: ringRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: ringRect.insetBy(dx: 3, dy: 3))
        guard let cgImage = context.makeImage() else {
            throw AutoPreviewRendererError.cursorImageUnavailable
        }
        return CIImage(cgImage: cgImage)
    }

    /// Letterbox fill for contain-layout reframes: the midpoint of the canvas
    /// gradient (or a near-black default) so bars blend into the packaging.
    nonisolated private static func canvasBackdrop(
        plan: AutoEditPlan,
        extent: CGRect
    ) -> CIImage {
        let base = CIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1)
        guard let canvas = plan.canvas else {
            return CIImage(color: base).cropped(to: extent)
        }
        let top = color(hex: canvas.backgroundTopHex, fallback: base)
        let bottom = color(hex: canvas.backgroundBottomHex, fallback: base)
        return CIImage(color: CIColor(
            red: (top.red + bottom.red) / 2,
            green: (top.green + bottom.green) / 2,
            blue: (top.blue + bottom.blue) / 2,
            alpha: 1
        )).cropped(to: extent)
    }

    /// Output canvas for a delivery aspect. Vertical/square reframes keep the
    /// source height and derive the width, snapped to even pixels; nil (or a
    /// matching aspect) returns the source size unchanged.
    nonisolated static func deliverySize(
        source: CGSize,
        aspectRatio: AutoEditPlan.Export.AspectRatio?
    ) -> CGSize {
        guard let aspectRatio,
              source.width > 1,
              source.height > 1 else { return source }
        let width: CGFloat
        switch aspectRatio {
        case .vertical9x16:
            width = source.height * 9 / 16
        case .square1x1:
            width = source.height
        }
        guard abs(width - source.width) > 1 else { return source }
        func even(_ value: CGFloat) -> CGFloat {
            let rounded = value.rounded(.down)
            return rounded - (rounded.truncatingRemainder(dividingBy: 2))
        }
        return CGSize(width: even(width), height: even(source.height))
    }

    nonisolated private static func renderFrame(
        _ source: CIImage,
        time: Double,
        plan: AutoEditPlan,
        cursorAssets: CursorRenderAssets,
        clickRingImage: CIImage,
        captionRenderer: CaptionOverlayRenderer?,
        videoAnnotationRenderer: VideoAnnotationRenderer?,
        cameraSampleInterval: Double,
        outputExtent: CGRect? = nil
    ) -> CIImage {
        let sourceExtent = source.extent
        let extent = CGRect(
            origin: .zero,
            size: outputExtent?.size ?? sourceExtent.size
        )
        let sourceTime = plan.timeline?.position(atOutputTime: time)?.sourceTimeSeconds
            ?? time
        let sourceFrame = videoAnnotationRenderer?.apply(
            to: source,
            atOutputTime: time,
            timeline: plan.timeline
        ) ?? source
        let camera = EffectTimeline.effectiveCameraState(
            at: sourceTime,
            camera: plan.camera
        )
        // Reframed deliveries contain-fit the source at zoom 1 (letterbox with
        // the canvas backdrop) and let camera zoom crop into it; same-aspect
        // deliveries degenerate to the legacy viewport math exactly.
        let baseScale = min(
            extent.width / max(sourceExtent.width, 1),
            extent.height / max(sourceExtent.height, 1)
        )
        let scale = max(camera.scale, 1) * max(baseScale, 0.001)
        let viewportSize = CGSize(
            width: min(extent.width / scale, sourceExtent.width),
            height: min(extent.height / scale, sourceExtent.height)
        )
        let requestedCenter = CGPoint(
            x: sourceExtent.minX + camera.center.x * sourceExtent.width,
            y: sourceExtent.minY + (1 - camera.center.y) * sourceExtent.height
        )
        func clampedAxis(
            requested: CGFloat,
            viewportLength: CGFloat,
            sourceMin: CGFloat,
            sourceLength: CGFloat
        ) -> CGFloat {
            guard viewportLength < sourceLength else {
                return sourceMin + (sourceLength - viewportLength) / 2
            }
            return min(
                max(requested - viewportLength / 2, sourceMin),
                sourceMin + sourceLength - viewportLength
            )
        }
        let viewport = CGRect(
            x: clampedAxis(
                requested: requestedCenter.x,
                viewportLength: viewportSize.width,
                sourceMin: sourceExtent.minX,
                sourceLength: sourceExtent.width
            ),
            y: clampedAxis(
                requested: requestedCenter.y,
                viewportLength: viewportSize.height,
                sourceMin: sourceExtent.minY,
                sourceLength: sourceExtent.height
            ),
            width: viewportSize.width,
            height: viewportSize.height
        )

        let contentSize = CGSize(
            width: viewport.width * scale,
            height: viewport.height * scale
        )
        let content = sourceFrame
            .cropped(to: viewport)
            .transformed(by: CGAffineTransform(
                translationX: -viewport.minX,
                y: -viewport.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var frame: CIImage
        if contentSize.width < extent.width - 0.5
            || contentSize.height < extent.height - 0.5 {
            // Contain layout: center the content and fill the letterbox with
            // the canvas backdrop color so the reframe reads as packaging,
            // not as dead black bars.
            let backdrop = canvasBackdrop(plan: plan, extent: extent)
            frame = content
                .transformed(by: CGAffineTransform(
                    translationX: (extent.width - contentSize.width) / 2,
                    y: (extent.height - contentSize.height) / 2
                ))
                .composited(over: backdrop)
                .cropped(to: extent)
        } else {
            frame = content.cropped(to: extent)
        }

        frame = applyCameraMotionBlur(
            to: frame,
            at: sourceTime,
            camera: plan.camera,
            extent: CGRect(origin: .zero, size: extent.size),
            sampleInterval: cameraSampleInterval
        )

        if let interaction = plan.interaction, interaction.showsClickPulse {
            frame = applyClickFeedback(
                to: frame,
                at: sourceTime,
                interaction: interaction,
                viewport: viewport,
                cameraScale: scale,
                extent: extent,
                clickRingImage: clickRingImage
            )
        }

        let followParameters = plan.cursor.resolvedSmoothingParameters
        let cursorPosition = plan.cursor.isEnabled == false
            ? nil
            : EffectTimeline.cursorPosition(
                at: sourceTime,
                keyframes: plan.cursor.keyframes,
                smoothing: followParameters.smoothing,
                smoothingWindowMilliseconds: followParameters.windowMilliseconds
            )
        let cursorOpacity: Double = {
            guard plan.cursor.hidesWhenIdle,
                  let lastActivity = EffectTimeline.lastCursorActivity(
                      at: sourceTime,
                      keyframes: plan.cursor.keyframes
                  ) else { return 1 }
            let idleElapsed = max(sourceTime - lastActivity - 1.35, 0)
            return 1 - min(idleElapsed / 0.35, 1)
        }()

        if let cursorPosition, cursorOpacity > 0.001 {
            let screenPoint = CGPoint(
                x: extent.width * cursorPosition.x,
                y: extent.height * (1 - cursorPosition.y)
            )
            let outputPoint = CGPoint(
                x: (screenPoint.x - viewport.minX) * scale,
                y: (screenPoint.y - viewport.minY) * scale
            )
            let cursorAsset = resolvedCursorAsset(
                at: sourceTime,
                cursor: plan.cursor,
                assets: cursorAssets
            )
            let targetCursorWidth = Self.baseCursorWidth(
                sourcePixelWidth: extent.width
            )
                * plan.cursor.scale
                * cursorAsset.relativeWidth
            frame = applyCursorMotionEffect(
                to: frame,
                at: sourceTime,
                cursor: plan.cursor,
                currentPosition: cursorPosition,
                currentOutputPoint: outputPoint,
                cursorAsset: cursorAsset,
                targetCursorWidth: targetCursorWidth,
                opacity: cursorOpacity,
                viewport: viewport,
                cameraScale: scale,
                extent: extent
            )
            if EffectTimeline.cursorKind(
                at: sourceTime,
                keyframes: plan.cursor.keyframes
            ) == .dragged {
                let accent = color(
                    hex: plan.cursor.accentColorHex,
                    fallback: CIColor(red: 0.36, green: 0.84, blue: 1)
                )
                let dragRing = clickRingLayer(
                    clickRingImage,
                    width: targetCursorWidth * 1.65,
                    center: outputPoint,
                    color: accent,
                    opacity: 0.78
                )
                let dragGlow = radialGlowLayer(
                    center: outputPoint,
                    radius: targetCursorWidth * 1.15,
                    color: accent,
                    opacity: 0.24
                )
                frame = dragGlow.composited(over: frame)
                frame = dragRing.composited(over: frame)
            }
            var positionedCursor = cursorLayer(
                asset: cursorAsset,
                width: targetCursorWidth,
                hotSpot: outputPoint,
                opacity: cursorOpacity
            )
            if plan.cursor.appearance == .minimalDot {
                positionedCursor = tint(
                    positionedCursor,
                    color: color(
                        hex: plan.cursor.accentColorHex,
                        fallback: CIColor(red: 0.36, green: 0.84, blue: 1)
                    ),
                    opacity: 1
                )
            }
            frame = positionedCursor.composited(over: frame)
            switch plan.cursor.appearance {
            case .ring:
                frame = proceduralCursorOverlay(
                    appearance: .ring,
                    at: outputPoint,
                    width: targetCursorWidth,
                    accent: color(
                        hex: plan.cursor.accentColorHex,
                        fallback: CIColor(red: 0.36, green: 0.84, blue: 1)
                    ),
                    opacity: cursorOpacity
                ).composited(over: frame)
            case .glowDot:
                frame = proceduralCursorOverlay(
                    appearance: .glowDot,
                    at: outputPoint,
                    width: targetCursorWidth,
                    accent: color(
                        hex: plan.cursor.accentColorHex,
                        fallback: CIColor(red: 0.36, green: 0.84, blue: 1)
                    ),
                    opacity: cursorOpacity
                ).composited(over: frame)
            case .recorded, .macOS, .highContrast, .minimalDot:
                break
            }
        }
        frame = frame.cropped(to: CGRect(origin: .zero, size: extent.size))
        if let canvas = plan.canvas, canvas.isEnabled {
            frame = applyCanvas(
                canvas,
                to: frame,
                extent: CGRect(origin: .zero, size: extent.size)
            )
        }
        if let interaction = plan.interaction,
           interaction.showsKeystrokes,
           interaction.keystrokes.isEmpty == false {
            frame = applyKeystrokes(
                to: frame,
                at: sourceTime,
                interaction: interaction,
                extent: CGRect(origin: .zero, size: extent.size)
            )
        }
        return captionRenderer?.apply(to: frame, at: time) ?? frame
    }

    nonisolated private static func resolvedCursorAsset(
        at sourceTime: Double,
        cursor: AutoEditPlan.Cursor,
        assets: CursorRenderAssets
    ) -> CursorRenderAsset {
        switch cursor.appearance {
        case .macOS:
            return assets.arrow
        case .highContrast:
            return assets.highContrast
        case .minimalDot:
            return assets.minimalDot
        case .ring, .glowDot:
            // Procedural overlays stack on top of the recorded glyph.
            return assets.arrow
        case .recorded:
            let shape = cursor.shapeKeyframes.last {
                $0.time <= sourceTime
            }?.shape ?? .arrow
            return assets.system[shape] ?? assets.arrow
        }
    }

    nonisolated private static func cursorLayer(
        asset: CursorRenderAsset,
        width: CGFloat,
        hotSpot: CGPoint,
        opacity: Double
    ) -> CIImage {
        let scale = width / max(asset.image.extent.width, 1)
        var image = asset.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let hotSpotX = image.extent.width * asset.hotSpot.x
        let hotSpotYFromBottom = image.extent.height * (1 - asset.hotSpot.y)
        image = image.transformed(by: CGAffineTransform(
            translationX: hotSpot.x - image.extent.minX - hotSpotX,
            y: hotSpot.y - image.extent.minY - hotSpotYFromBottom
        ))
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
        ])
    }

    nonisolated private static func applyCursorMotionEffect(
        to frame: CIImage,
        at sourceTime: Double,
        cursor: AutoEditPlan.Cursor,
        currentPosition: LensPoint,
        currentOutputPoint: CGPoint,
        cursorAsset: CursorRenderAsset,
        targetCursorWidth: CGFloat,
        opacity: Double,
        viewport: CGRect,
        cameraScale: CGFloat,
        extent: CGRect
    ) -> CIImage {
        guard cursor.motionEffect != .none,
              cursor.motionEffectStrength > 0,
              opacity > 0.001 else { return frame }
        let accent = color(
            hex: cursor.accentColorHex,
            fallback: CIColor(red: 0.36, green: 0.84, blue: 1)
        )
        let strength = min(max(cursor.motionEffectStrength, 0.1), 1) * opacity
        var result = frame

        switch cursor.motionEffect {
        case .none:
            break
        case .halo:
            let glow = radialGlowLayer(
                center: currentOutputPoint,
                radius: targetCursorWidth * (0.72 + 0.38 * strength),
                color: accent,
                opacity: 0.34 * strength
            )
            result = glow.composited(over: result)
        case .spotlight:
            let glow = radialGlowLayer(
                center: currentOutputPoint,
                radius: max(targetCursorWidth * 2.5, extent.width * 0.035),
                color: accent,
                opacity: 0.30 * strength
            )
            result = glow.composited(over: result)
        case .trail:
            let samples: [(offset: Double, alpha: Double)] = [
                (0.025, 0.30), (0.055, 0.21), (0.09, 0.13), (0.13, 0.07)
            ]
            let followParameters = cursor.resolvedSmoothingParameters
            for sample in samples.reversed() {
                guard let position = EffectTimeline.cursorPosition(
                    at: max(sourceTime - sample.offset, 0),
                    keyframes: cursor.keyframes,
                    smoothing: followParameters.smoothing,
                    smoothingWindowMilliseconds: followParameters.windowMilliseconds
                ) else { continue }
                let movement = hypot(
                    position.x - currentPosition.x,
                    position.y - currentPosition.y
                )
                guard movement > 0.0015 else { continue }
                let screenPoint = CGPoint(
                    x: extent.width * position.x,
                    y: extent.height * (1 - position.y)
                )
                let outputPoint = CGPoint(
                    x: (screenPoint.x - viewport.minX) * cameraScale,
                    y: (screenPoint.y - viewport.minY) * cameraScale
                )
                let ghost = cursorLayer(
                    asset: cursorAsset,
                    width: targetCursorWidth,
                    hotSpot: outputPoint,
                    opacity: sample.alpha * strength
                ).applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: 0.7 + sample.offset * 11
                ])
                result = ghost.composited(over: result)
            }
        }
        return result.cropped(to: extent)
    }

    /// Burns an impact glow and two expanding rings into the final frame. The
    /// click stays legible even when the pointer itself is small or hidden.
    private final class CachedKeystrokeCapsule: NSObject {
        let image: CIImage

        init(image: CIImage) {
            self.image = image
        }
    }

    /// Draws the currently held keystroke capsules onto the finished canvas.
    /// Capsules live above the canvas (like captions) so they never scale with
    /// camera zoom, and only shortcuts/control keys recorded by the privacy
    /// filter can ever appear here.
    nonisolated static func applyKeystrokes(
        to frame: CIImage,
        at sourceTime: Double,
        interaction: AutoEditPlan.Interaction,
        extent: CGRect
    ) -> CIImage {
        let active = interaction.keystrokes
            .filter { keystroke in
                sourceTime >= keystroke.time
                    && sourceTime < keystroke.time + keystroke.holdSeconds
            }
            .suffix(3)
        guard !active.isEmpty else { return frame }
        let opacity = active
            .map { keystroke -> Double in
                let elapsed = sourceTime - keystroke.time
                let remaining = keystroke.time + keystroke.holdSeconds - sourceTime
                return min(elapsed / 0.08, 1) * min(remaining / 0.30, 1)
            }
            .min() ?? 1
        guard opacity > 0.01 else { return frame }

        let fontSize = max(
            14,
            min(extent.width * 0.018, extent.height * 0.038)
        )
        let text = active.map(\.text).joined(separator: "\u{2009}\u{2009}")
        let image = keystrokeCapsuleImage(text: text, fontSize: fontSize)
        let scale = min(
            extent.width * 0.42 / max(image.extent.width, 1),
            1
        )
        let margin = min(extent.width, extent.height) * 0.042
        let target = CGRect(
            x: extent.maxX - image.extent.width * scale - margin,
            y: extent.minY + extent.height * 0.055,
            width: image.extent.width * scale,
            height: image.extent.height * scale
        ).integral
        let positioned = image
            .transformed(by: CGAffineTransform(
                translationX: target.minX - image.extent.minX,
                y: target.minY - image.extent.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(
                    x: 0,
                    y: 0,
                    z: 0,
                    w: CGFloat(min(max(opacity, 0), 1))
                )
            ])
            .cropped(to: extent)
        return positioned.composited(over: frame).cropped(to: extent)
    }

    /// Pure CoreGraphics capsule so rendering stays safe on the compositor's
    /// background queue (no AppKit drawing).
    nonisolated private static func keystrokeCapsuleImage(
        text: String,
        fontSize: CGFloat
    ) -> CIImage {
        let key = NSString(string: "\(text)|\(Int(fontSize.rounded()))")
        if let cached = Self.keystrokeCapsuleCache.object(forKey: key) {
            return cached.image
        }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: 1,
                green: 1,
                blue: 1,
                alpha: 0.97
            )
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        let typographicWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let horizontalPadding = fontSize * 0.78
        let verticalPadding = fontSize * 0.44
        let width = max(Int(ceil(typographicWidth) + horizontalPadding * 2), 1)
        let height = max(Int(fontSize + verticalPadding * 2), 1)
        let capsule: CIImage
        if let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            let bounds = CGRect(
                x: 0.5,
                y: 0.5,
                width: CGFloat(width) - 1,
                height: CGFloat(height) - 1
            )
            let path = CGPath(
                roundedRect: bounds,
                cornerWidth: CGFloat(height) * 0.34,
                cornerHeight: CGFloat(height) * 0.34,
                transform: nil
            )
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -fontSize * 0.08),
                blur: fontSize * 0.3,
                color: CGColor(gray: 0, alpha: 0.4)
            )
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0.06, alpha: 0.86))
            context.fillPath()
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
            context.setLineWidth(max(1, fontSize * 0.03))
            context.strokePath()
            context.textPosition = CGPoint(
                x: horizontalPadding,
                y: verticalPadding + fontSize * 0.18
            )
            CTLineDraw(line, context)
            capsule = context.makeImage().map { CIImage(cgImage: $0) }
                ?? CIImage.empty()
        } else {
            capsule = CIImage.empty()
        }
        Self.keystrokeCapsuleCache.setObject(
            CachedKeystrokeCapsule(image: capsule),
            forKey: key
        )
        return capsule
    }

    /// NSCache is thread-safe; the `nonisolated(unsafe)` marker is required
    /// because frame rendering runs off the main actor.
    nonisolated(unsafe) private static let keystrokeCapsuleCache =
        NSCache<NSString, CachedKeystrokeCapsule>()

    nonisolated static func applyClickFeedback(
        to frame: CIImage,
        at sourceTime: Double,
        interaction: AutoEditPlan.Interaction,
        viewport: CGRect,
        cameraScale: CGFloat,
        extent: CGRect,
        clickRingImage: CIImage
    ) -> CIImage {
        guard interaction.showsClickPulse else { return frame }
        var result = frame
        let pulseColor = color(
            hex: interaction.clickPulseColorHex,
            fallback: CIColor(red: 1, green: 0.41, blue: 0.30)
        )
        for pulse in interaction.clickPulses {
            let elapsed = sourceTime - pulse.time
            let duration = interaction.clickPulseDuration ?? pulse.duration
            guard elapsed >= 0, elapsed <= duration else { continue }
            let progress = min(max(elapsed / duration, 0), 1)
            let eased = progress * progress * (3 - 2 * progress)
            let strength = min(max(interaction.clickEffectStrength, 0.1), 1)
            let opacity = pow(1 - progress, 0.68) * strength
            let screenPoint = CGPoint(
                x: extent.width * pulse.position.x,
                y: extent.height * (1 - pulse.position.y)
            )
            let outputPoint = CGPoint(
                x: (screenPoint.x - viewport.minX) * cameraScale,
                y: (screenPoint.y - viewport.minY) * cameraScale
            )

            switch interaction.clickEffect {
            case .ripple:
                let primaryWidth = extent.width
                    * (0.020 + 0.035 * eased)
                    * interaction.clickPulseScale
                let primaryRing = clickRingLayer(
                    clickRingImage,
                    width: primaryWidth,
                    center: outputPoint,
                    color: pulseColor,
                    opacity: opacity
                )
                let glow = primaryRing
                    .applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: max(primaryWidth * 0.055, 1.5)
                    ])
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.48)
                    ])
                result = glow.composited(over: result)
                result = primaryRing.composited(over: result)

                let echoProgress = min(max((progress - 0.12) / 0.88, 0), 1)
                if echoProgress > 0 {
                    let echoEased = echoProgress * echoProgress * (3 - 2 * echoProgress)
                    let echoWidth = extent.width
                        * (0.014 + 0.030 * echoEased)
                        * interaction.clickPulseScale
                    let echoRing = clickRingLayer(
                        clickRingImage,
                        width: echoWidth,
                        center: outputPoint,
                        color: pulseColor,
                        opacity: 0.68 * pow(1 - echoProgress, 0.72) * strength
                    )
                    result = echoRing.composited(over: result)
                }
            case .pulse:
                let pulseArc = sin(Double.pi * min(progress / 0.78, 1))
                let radius = extent.width
                    * (0.014 + 0.018 * pulseArc)
                    * interaction.clickPulseScale
                let impact = radialGlowLayer(
                    center: outputPoint,
                    radius: radius,
                    color: pulseColor,
                    opacity: (0.36 + 0.28 * pulseArc) * opacity
                )
                result = impact.composited(over: result)
                let compactRing = clickRingLayer(
                    clickRingImage,
                    width: radius * 1.12,
                    center: outputPoint,
                    color: pulseColor,
                    opacity: opacity * 0.82
                )
                result = compactRing.composited(over: result)
            case .spotlight:
                let radius = extent.width
                    * (0.035 + 0.020 * eased)
                    * interaction.clickPulseScale
                let spotlight = radialGlowLayer(
                    center: outputPoint,
                    radius: radius,
                    color: pulseColor,
                    opacity: opacity * 0.48
                )
                result = spotlight.composited(over: result)
                let focusRing = clickRingLayer(
                    clickRingImage,
                    width: radius * (0.62 + 0.18 * eased),
                    center: outputPoint,
                    color: pulseColor,
                    opacity: opacity * 0.62
                )
                result = focusRing.composited(over: result)
            }
        }
        return result.cropped(to: extent)
    }

    nonisolated private static func clickRingLayer(
        _ image: CIImage,
        width: CGFloat,
        center: CGPoint,
        color: CIColor,
        opacity: Double
    ) -> CIImage {
        let scale = width / max(image.extent.width, 1)
        var ring = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        ring = ring.transformed(by: CGAffineTransform(
            translationX: center.x - ring.extent.midX,
            y: center.y - ring.extent.midY
        ))
        return ring.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: color.red),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: color.green),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: color.blue),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
        ])
    }

    nonisolated private static func tint(
        _ image: CIImage,
        color: CIColor,
        opacity: Double
    ) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: color.red),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: color.green),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: color.blue),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
        ])
    }

    /// Laser-pointer ring and glowing dot cursors, drawn procedurally so
    /// they follow the accent color and scale without bitmap assets. Centered
    /// on the hotspot; the underlying recorded glyph stays visible beneath.
    nonisolated private static func proceduralCursorOverlay(
        appearance: AutoEditPlan.Cursor.Appearance,
        at point: CGPoint,
        width: CGFloat,
        accent: CIColor,
        opacity: Double
    ) -> CIImage {
        let safeOpacity = min(max(opacity, 0), 1)
        switch appearance {
        case .ring:
            let radius = max(width * 0.62, 6)
            // Soft inner fill plus a bright edge band fading outward reads as
            // a laser-pointer ring without any mask passes.
            let fillFilter = CIFilter.radialGradient()
            fillFilter.center = point
            fillFilter.radius0 = 0
            fillFilter.radius1 = Float(radius)
            fillFilter.color0 = CIColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: 0.10 * safeOpacity
            )
            fillFilter.color1 = CIColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: 0
            )
            let fill = fillFilter.outputImage ?? CIImage.empty()
            let ringFilter = CIFilter.radialGradient()
            ringFilter.center = point
            ringFilter.radius0 = Float(radius * 0.80)
            ringFilter.radius1 = Float(radius)
            ringFilter.color0 = CIColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: 0.95 * safeOpacity
            )
            ringFilter.color1 = CIColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: 0
            )
            let ring = ringFilter.outputImage ?? CIImage.empty()
            return ring.composited(over: fill).cropped(to: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        case .glowDot:
            let radius = max(width * 0.34, 5)
            let dot = radialGlowLayer(
                center: point,
                radius: radius,
                color: accent,
                opacity: 0.98 * safeOpacity
            )
            let halo = radialGlowLayer(
                center: point,
                radius: radius * 2.1,
                color: accent,
                opacity: 0.30 * safeOpacity
            )
            return dot.composited(over: halo).cropped(to: CGRect(
                x: point.x - radius * 2.1,
                y: point.y - radius * 2.1,
                width: radius * 4.2,
                height: radius * 4.2
            ))
        case .recorded, .macOS, .highContrast, .minimalDot:
            return CIImage.empty()
        }
    }

    nonisolated private static func radialGlowLayer(
        center: CGPoint,
        radius: CGFloat,
        color: CIColor,
        opacity: Double
    ) -> CIImage {
        let safeRadius = max(radius, 1)
        let safeOpacity = min(max(opacity, 0), 1)
        let filter = CIFilter.radialGradient()
        filter.center = center
        filter.radius0 = 0
        filter.radius1 = Float(safeRadius)
        filter.color0 = CIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: safeOpacity
        )
        filter.color1 = CIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 0
        )
        return filter.outputImage!.cropped(to: CGRect(
            x: center.x - safeRadius,
            y: center.y - safeRadius,
            width: safeRadius * 2,
            height: safeRadius * 2
        ))
    }

    nonisolated static func applyCameraMotionBlur(
        to image: CIImage,
        at sourceTime: Double,
        camera: AutoEditPlan.Camera,
        extent: CGRect,
        sampleInterval: Double = 1.0 / 30.0
    ) -> CIImage {
        let strength = min(max(
            camera.motionBlurStrength.isFinite ? camera.motionBlurStrength : 0,
            0
        ), 1)
        guard strength > 0.000_1,
              camera.mode != "off",
              extent.width > 1,
              extent.height > 1 else {
            return image
        }

        let interval = min(max(
            sampleInterval.isFinite ? sampleInterval : 1.0 / 30.0,
            1.0 / 240.0
        ), 1.0 / 12.0)
        let before = EffectTimeline.effectiveCameraState(
            at: max(sourceTime - interval / 2, 0),
            camera: camera
        )
        let after = EffectTimeline.effectiveCameraState(
            at: sourceTime + interval / 2,
            camera: camera
        )
        let averageScale = max((before.scale + after.scale) / 2, 1)
        let panX = (after.center.x - before.center.x) * extent.width * averageScale
        let panY = -(after.center.y - before.center.y) * extent.height * averageScale
        let scaleRatio = max(after.scale, 0.001) / max(before.scale, 0.001)
        let panVelocity = hypot(panX, panY) / interval
        let zoomVelocity = abs(log(scaleRatio)) / interval
        let normalizedPanVelocity = normalizedMotionVelocity(
            panVelocity,
            deadZone: 24,
            fullStrength: 1_500
        )
        let normalizedZoomVelocity = normalizedMotionVelocity(
            zoomVelocity,
            deadZone: 0.025,
            fullStrength: 1.60
        )
        let dominantVelocity = max(normalizedPanVelocity, normalizedZoomVelocity)
        guard dominantVelocity > 0 else { return image }
        let smoothVelocity = dominantVelocity * dominantVelocity
            * (3 - 2 * dominantVelocity)
        let motionBudget = cameraMotionBlurBudget(
            at: sourceTime,
            camera: camera,
            sampleInterval: interval
        )
        let blurEnergy = sqrt(strength)
            * smoothVelocity
            * motionBudget.envelope
            * motionBudget.intensity
        guard blurEnergy > 0.01 else { return image }

        let baseRadius: Double = switch camera.generationStrength {
        case .restrained: 8
        case .balanced: 11
        case .active: 14
        }
        let resolutionScale = min(max(
            max(extent.width, extent.height) / 1_380,
            0.25
        ), 2)
        let radiusCap = baseRadius * resolutionScale
        let radius = min(blurEnergy * radiusCap, radiusCap)
        guard radius >= 0.25 else { return image }

        if normalizedZoomVelocity >= normalizedPanVelocity {
            return image.applyingFilter(
                "CIZoomBlur",
                parameters: [
                    kCIInputCenterKey: CIVector(
                        x: extent.midX,
                        y: extent.midY
                    ),
                    kCIInputAmountKey: radius
                ]
            ).cropped(to: extent)
        }
        return image.applyingFilter(
            "CIMotionBlur",
            parameters: [
                kCIInputRadiusKey: radius,
                kCIInputAngleKey: atan2(panY, panX)
            ]
        ).cropped(to: extent)
    }

    nonisolated private static func normalizedMotionVelocity(
        _ value: Double,
        deadZone: Double,
        fullStrength: Double
    ) -> Double {
        guard value.isFinite, fullStrength > deadZone else { return 0 }
        return min(max((value - deadZone) / (fullStrength - deadZone), 0), 1)
    }

    /// Motion blur is a short transition accent, not a persistent softening
    /// layer. Long camera moves receive a bounded center window, and the small
    /// corrections generated by pointer following remain mostly crisp.
    nonisolated private static func cameraMotionBlurBudget(
        at time: Double,
        camera: AutoEditPlan.Camera,
        sampleInterval: Double
    ) -> (envelope: Double, intensity: Double) {
        let keyframes = EffectTimeline.effectiveCameraKeyframes(for: camera)
        guard let nextIndex = keyframes.firstIndex(where: { $0.time >= time }),
              nextIndex > 0 else { return (0, 0) }
        let previous = keyframes[nextIndex - 1]
        let next = keyframes[nextIndex]
        let transitionDuration = next.time - previous.time
        guard transitionDuration > 0 else { return (0, 0) }

        let maximumWindow: Double = switch camera.generationStrength {
        case .restrained: 0.14
        case .balanced: 0.18
        case .active: 0.22
        }
        let halfWindow = min(
            transitionDuration / 2,
            max(maximumWindow / 2, sampleInterval * 1.5)
        )
        let midpoint = (previous.time + next.time) / 2
        let linearEnvelope = min(max(
            1 - abs(time - midpoint) / max(halfWindow, 0.000_001),
            0
        ), 1)
        let envelope = linearEnvelope * linearEnvelope * (3 - 2 * linearEnvelope)
        let intensity: Double = switch next.reason {
        case .pointerFollow: 0.22
        case .returnToOverview, .manualReturn: 0.72
        case .baseline, .clickHold, .manualAnchor, .manualHold: 0.45
        case .clickFocus, .manualFocus: 1
        }
        return (envelope, intensity)
    }

    nonisolated private static func applyCanvas(
        _ canvas: AutoEditPlan.Canvas,
        to frame: CIImage,
        extent: CGRect
    ) -> CIImage {
        let marginX = extent.width * min(max(canvas.margin, 0), 0.25)
        let marginY = extent.height * min(max(canvas.margin, 0), 0.25)
        let stageRect = extent.insetBy(dx: marginX, dy: marginY)
        guard stageRect.width > 1, stageRect.height > 1 else { return frame }

        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: extent.midX, y: extent.maxY)
        gradient.point1 = CGPoint(x: extent.midX, y: extent.minY)
        gradient.color0 = color(hex: canvas.backgroundTopHex, fallback: CIColor(red: 0.85, green: 0.84, blue: 0.81))
        gradient.color1 = color(hex: canvas.backgroundBottomHex, fallback: CIColor(red: 0.62, green: 0.66, blue: 0.65))
        let background = (gradient.outputImage ?? CIImage(color: gradient.color0)).cropped(to: extent)

        let scaleX = stageRect.width / extent.width
        let scaleY = stageRect.height / extent.height
        let stageTransform = CGAffineTransform(
            translationX: stageRect.minX,
            y: stageRect.minY
        ).scaledBy(x: scaleX, y: scaleY)
        let stagedFrame = frame.transformed(by: stageTransform)

        let maskGenerator = CIFilter.roundedRectangleGenerator()
        maskGenerator.extent = stageRect
        maskGenerator.radius = Float(min(extent.width, extent.height) * canvas.cornerRadius)
        maskGenerator.color = .white
        let mask = (maskGenerator.outputImage ?? CIImage(color: .white).cropped(to: stageRect))
            .cropped(to: extent)
        let clear = CIImage(color: .clear).cropped(to: extent)
        let roundedFrame = stagedFrame.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ]
        ).cropped(to: extent)

        let shadowColor = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: canvas.shadowOpacity)
        ).cropped(to: extent)
        let shadowShape = shadowColor.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ]
        )
        let shadow = shadowShape
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: min(extent.width, extent.height) * 0.018])
            .transformed(by: CGAffineTransform(translationX: 0, y: -extent.height * 0.012))
            .cropped(to: extent)

        return roundedFrame
            .composited(over: shadow.composited(over: background))
            .cropped(to: extent)
    }

    nonisolated private static func color(hex: String, fallback: CIColor) -> CIColor {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let integer = UInt32(value, radix: 16) else { return fallback }
        return CIColor(
            red: CGFloat((integer >> 16) & 0xFF) / 255,
            green: CGFloat((integer >> 8) & 0xFF) / 255,
            blue: CGFloat(integer & 0xFF) / 255,
            alpha: 1
        )
    }
}
