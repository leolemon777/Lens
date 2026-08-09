import CoreGraphics
import Foundation
import ScreenTraceCore

struct ScreenshotEditingResult {
    let trace: SavedTrace
    let renderedImage: CGImage
    let renderedImageURL: URL
}

struct ScreenshotEditingService {
    let store: TraceProjectStore
    private let renderer = ScreenshotAnnotationRenderer()

    func renderAndSave(
        source: CGImage,
        plan: ScreenshotEditPlan,
        trace: SavedTrace
    ) throws -> ScreenshotEditingResult {
        let rendered = try renderer.render(source: source, plan: plan)
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
}
