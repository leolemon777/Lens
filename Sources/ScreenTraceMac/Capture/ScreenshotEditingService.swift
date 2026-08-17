import CoreGraphics
import Foundation
import ScreenTraceCore

struct ScreenshotEditingResult: @unchecked Sendable {
    let trace: SavedTrace
    let renderedImage: CGImage
    let renderedImageURL: URL
}

struct ScreenshotEditingService: Sendable {
    let store: TraceProjectStore
    private let renderer = ScreenshotAnnotationRenderer()

    func render(source: CGImage, plan: ScreenshotEditPlan) throws -> CGImage {
        try renderer.render(source: source, plan: plan)
    }

    func renderAndSave(
        source: CGImage,
        plan: ScreenshotEditPlan,
        trace: SavedTrace
    ) throws -> ScreenshotEditingResult {
        let rendered = try render(source: source, plan: plan)
        let pngData = try ImageEncoding.pngData(from: rendered)
        let outputURL = trace.packageURL.appendingPathComponent("previews/annotated.png")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL, options: .atomic)
        _ = try store.writeScreenshotEditPlan(plan, to: trace)
        let completed = try store.completeScreenshotEditing(
            packageURL: trace.packageURL,
            renderedImageURL: outputURL
        )
        return ScreenshotEditingResult(
            trace: completed,
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
