import AVFoundation
import CoreGraphics
import Foundation
import LensCore
import UniformTypeIdentifiers

enum StepDocumentExportError: LocalizedError {
    case noSteps
    case frameUnavailable(Double)

    var errorDescription: String? {
        switch self {
        case .noSteps:
            "这段录制里没有可用的点击事件，无法生成步骤文档。"
        case let .frameUnavailable(time):
            String(format: "无法提取第 %.1f 秒的画面，请重试。", time)
        }
    }
}

/// Writes a generated step document (Markdown + one frame per step) into a
/// user-chosen location. Pure delivery: the plan itself comes from
/// `StepDocumentPlanner` in the core.
struct StepDocumentExporter: Sendable {
    let document: StepDocument
    let videoURL: URL

    func write(to markdownURL: URL) async throws {
        guard !document.steps.isEmpty else { throw StepDocumentExportError.noSteps }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let directory = markdownURL.deletingLastPathComponent()

        for step in document.steps {
            let frame = try await generator.image(
                at: CMTime(seconds: step.time, preferredTimescale: 600)
            )
            let imageName = String(format: "step-%02d.png", step.index)
            let imageURL = directory.appendingPathComponent(imageName)
            let destination = CGImageDestinationCreateWithURL(
                imageURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
            guard let destination else {
                throw StepDocumentExportError.frameUnavailable(step.time)
            }
            CGImageDestinationAddImage(destination, frame.image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw StepDocumentExportError.frameUnavailable(step.time)
            }
        }
        try document.markdown.data(using: .utf8)?.write(
            to: markdownURL,
            options: .atomic
        )
    }
}
