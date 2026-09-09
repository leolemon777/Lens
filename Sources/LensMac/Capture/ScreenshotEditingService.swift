import CoreGraphics
import Foundation
import LensCore

struct ScreenshotEditingResult: @unchecked Sendable {
    let lens: SavedLens
    let renderedImage: CGImage
    let renderedImageURL: URL
}

struct ScreenshotEditingService: Sendable {
    let store: LensProjectStore
    private let renderer = ScreenshotAnnotationRenderer()

    func render(source: CGImage, plan: ScreenshotEditPlan) throws -> CGImage {
        try renderer.render(source: source, plan: plan)
    }

    func renderAndSave(
        source: CGImage,
        plan: ScreenshotEditPlan,
        lens: SavedLens
    ) throws -> ScreenshotEditingResult {
        let rendered = try render(source: source, plan: plan)
        let pngData = try ImageEncoding.pngData(from: rendered)
        let outputURL = lens.packageURL.appendingPathComponent("previews/annotated.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL, options: .atomic)
        NotificationCenter.default.post(
            name: .lensThumbnailDidChange,
            object: outputURL
        )
        _ = try store.writeScreenshotEditPlan(plan, to: lens)
        let completed = try store.completeScreenshotEditing(
            packageURL: lens.packageURL,
            renderedImageURL: outputURL
        )
        return ScreenshotEditingResult(
            lens: completed,
            renderedImage: rendered,
            renderedImageURL: outputURL
        )
    }

    func export(
        image: CGImage,
        to outputURL: URL,
        format: ScreenshotExportFormat
    ) throws {
        let data = try ImageEncoding.data(from: image, format: format)
        try data.write(to: outputURL, options: .atomic)
    }
}
