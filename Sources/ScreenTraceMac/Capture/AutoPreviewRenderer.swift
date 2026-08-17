import AppKit
@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ScreenTraceCore

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
        transcript: TranscriptDocument? = nil
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
                appliesTimeline: transitionedInputURL == nil
            )
        }

        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".screen-effects-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = try await renderScreenEffects(
            inputURL: effectsInputURL,
            outputURL: temporaryURL,
            plan: plan,
            captionRenderer: captionRenderer,
            videoAnnotationRenderer: videoAnnotationRenderer,
            appliesTimeline: transitionedInputURL == nil
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
                captionCues: captionCues
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
        appliesTimeline: Bool
    ) async throws -> URL {
        let asset: AVAsset
        if appliesTimeline, let timeline = plan.timeline {
            asset = try await VideoTimelineCompositionBuilder().build(
                inputURL: inputURL,
                timeline: timeline,
                includesVideo: true,
                includesAudio: true,
                requiresVideo: true
            )
        } else {
            asset = AVURLAsset(url: inputURL)
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
                    cameraSampleInterval: cameraSampleInterval
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
        try await exporter.export(to: outputURL, as: .mp4)
        return outputURL
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

    nonisolated private static func renderFrame(
        _ source: CIImage,
        time: Double,
        plan: AutoEditPlan,
        cursorAssets: CursorRenderAssets,
        clickRingImage: CIImage,
        captionRenderer: CaptionOverlayRenderer?,
        videoAnnotationRenderer: VideoAnnotationRenderer?,
        cameraSampleInterval: Double
    ) -> CIImage {
        let extent = source.extent
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
        let scale = max(camera.scale, 1)
        let viewportSize = CGSize(
            width: extent.width / scale,
            height: extent.height / scale
        )
        let requestedCenter = CGPoint(
            x: extent.minX + camera.center.x * extent.width,
            y: extent.minY + (1 - camera.center.y) * extent.height
        )
        let viewport = CGRect(
            x: min(
                max(requestedCenter.x - viewportSize.width / 2, extent.minX),
                extent.maxX - viewportSize.width
            ),
            y: min(
                max(requestedCenter.y - viewportSize.height / 2, extent.minY),
                extent.maxY - viewportSize.height
            ),
            width: viewportSize.width,
            height: viewportSize.height
        )

        var frame = sourceFrame
            .cropped(to: viewport)
            .transformed(by: CGAffineTransform(
                translationX: -viewport.minX,
                y: -viewport.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: .zero, size: extent.size))

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

        let cursorPosition = plan.cursor.isEnabled == false
            ? nil
            : EffectTimeline.cursorPosition(
                at: sourceTime,
                keyframes: plan.cursor.keyframes,
                smoothing: plan.cursor.smoothing,
                smoothingWindowMilliseconds: plan.cursor.smoothingWindowMilliseconds
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
        }
        frame = frame.cropped(to: CGRect(origin: .zero, size: extent.size))
        if let canvas = plan.canvas, canvas.isEnabled {
            frame = applyCanvas(
                canvas,
                to: frame,
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
        currentPosition: TracePoint,
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
            for sample in samples.reversed() {
                guard let position = EffectTimeline.cursorPosition(
                    at: max(sourceTime - sample.offset, 0),
                    keyframes: cursor.keyframes,
                    smoothing: cursor.smoothing,
                    smoothingWindowMilliseconds: cursor.smoothingWindowMilliseconds
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
