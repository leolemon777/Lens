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

@MainActor
final class AutoPreviewRenderer {
    private(set) var lastPresenterCameraError: Error?

    func render(
        inputURL: URL,
        cameraURL: URL? = nil,
        outputURL: URL,
        plan: AutoEditPlan
    ) async throws -> URL {
        lastPresenterCameraError = nil
        guard let presenter = plan.presenterCamera,
              presenter.isEnabled,
              let cameraURL,
              FileManager.default.fileExists(atPath: cameraURL.path) else {
            return try await renderScreenEffects(
                inputURL: inputURL,
                outputURL: outputURL,
                plan: plan
            )
        }

        let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".screen-effects-\(UUID().uuidString).mp4"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        _ = try await renderScreenEffects(
            inputURL: inputURL,
            outputURL: temporaryURL,
            plan: plan
        )
        do {
            return try await PresenterCameraRenderer().render(
                screenURL: temporaryURL,
                cameraURL: cameraURL,
                outputURL: outputURL,
                layout: presenter,
                timeline: plan.timeline
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

    private func renderScreenEffects(
        inputURL: URL,
        outputURL: URL,
        plan: AutoEditPlan
    ) async throws -> URL {
        let asset: AVAsset
        if let timeline = plan.timeline {
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
        let cursorImage = try systemCursorImage()
        let clickRingImage = try clickRingImage()
        let composition = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AVVideoComposition, Error>) in
            AVVideoComposition.videoComposition(
                with: asset,
                applyingCIFiltersWithHandler: { request in
                let time = request.compositionTime.seconds
                let result = Self.renderFrame(
                    request.sourceImage,
                    time: time,
                    plan: plan,
                    cursorImage: cursorImage,
                    clickRingImage: clickRingImage
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

        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
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

    private func systemCursorImage() throws -> CIImage {
        let image = NSCursor.arrow.image
        var rect = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return CIImage(cgImage: cgImage)
        }
        return try fallbackCursorImage()
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
        cursorImage: CIImage,
        clickRingImage: CIImage
    ) -> CIImage {
        let extent = source.extent
        let sourceTime = plan.timeline?.position(atOutputTime: time)?.sourceTimeSeconds
            ?? time
        let plannedCamera = EffectTimeline.cameraState(
            at: sourceTime,
            keyframes: plan.camera.mode == "off" ? [] : plan.camera.keyframes
        )
        let intensityMultiplier = min(max(plan.camera.zoomIntensity, 0), 1) / 0.42
        let camera = CameraFrameState(
            scale: min(max(
                1 + (plannedCamera.scale - 1) * intensityMultiplier,
                1
            ), 3),
            center: plannedCamera.center
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

        var frame = source
            .cropped(to: viewport)
            .transformed(by: CGAffineTransform(
                translationX: -viewport.minX,
                y: -viewport.minY
            ))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: .zero, size: extent.size))

        if let interaction = plan.interaction, interaction.showsClickPulse {
            for pulse in interaction.clickPulses {
                let elapsed = sourceTime - pulse.time
                guard elapsed >= 0, elapsed <= pulse.duration else { continue }
                let progress = min(max(elapsed / pulse.duration, 0), 1)
                let eased = progress * progress * (3 - 2 * progress)
                let screenPoint = CGPoint(
                    x: extent.width * pulse.position.x,
                    y: extent.height * (1 - pulse.position.y)
                )
                let outputPoint = CGPoint(
                    x: (screenPoint.x - viewport.minX) * scale,
                    y: (screenPoint.y - viewport.minY) * scale
                )
                let targetWidth = extent.width * (0.018 + 0.026 * eased)
                let ringScale = targetWidth / max(clickRingImage.extent.width, 1)
                var ring = clickRingImage.transformed(
                    by: CGAffineTransform(scaleX: ringScale, y: ringScale)
                )
                ring = ring.transformed(by: CGAffineTransform(
                    translationX: outputPoint.x - ring.extent.midX,
                    y: outputPoint.y - ring.extent.midY
                ))
                ring = ring.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - eased)
                ])
                frame = ring.composited(over: frame)
            }
        }

        let cursorPosition = plan.cursor.isEnabled == false
            ? nil
            : EffectTimeline.cursorPosition(
                at: sourceTime,
                keyframes: plan.cursor.keyframes
            )
        let cursorIsIdle: Bool = {
            guard plan.cursor.hidesWhenIdle,
                      let lastActivity = EffectTimeline.lastCursorActivity(
                      at: sourceTime,
                      keyframes: plan.cursor.keyframes
                  ) else { return false }
            return sourceTime - lastActivity > 1.8
        }()

        if let cursorPosition, !cursorIsIdle {
            let screenPoint = CGPoint(
                x: extent.width * cursorPosition.x,
                y: extent.height * (1 - cursorPosition.y)
            )
            let outputPoint = CGPoint(
                x: (screenPoint.x - viewport.minX) * scale,
                y: (screenPoint.y - viewport.minY) * scale
            )
            let targetCursorWidth = min(max(extent.width * 0.012, 28), 72) * plan.cursor.scale
            let cursorScale = targetCursorWidth / max(cursorImage.extent.width, 1)
            let scaledCursor = cursorImage.transformed(
                by: CGAffineTransform(scaleX: cursorScale, y: cursorScale)
            )
            let positionedCursor = scaledCursor.transformed(by: CGAffineTransform(
                translationX: outputPoint.x - scaledCursor.extent.minX,
                y: outputPoint.y - scaledCursor.extent.maxY
            ))
            frame = positionedCursor.composited(over: frame)
        }
        frame = frame.cropped(to: CGRect(origin: .zero, size: extent.size))
        guard let canvas = plan.canvas, canvas.isEnabled else { return frame }
        return applyCanvas(canvas, to: frame, extent: CGRect(origin: .zero, size: extent.size))
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
