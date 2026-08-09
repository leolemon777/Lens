import CoreGraphics
import Foundation
import ScreenTraceCore
@preconcurrency import Vision

private final class OCRImageBox: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

struct VisionOCRService: Sendable {
    var preferredLanguages = ["zh-Hans", "en-US"]

    func recognizeText(in image: CGImage) async throws -> OCRDocument {
        let imageBox = OCRImageBox(image)
        let languages = preferredLanguages

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = languages
            request.minimumTextHeight = 0.006

            let handler = VNImageRequestHandler(cgImage: imageBox.image, options: [:])
            try handler.perform([request])

            let blocks = (request.results ?? [])
                .compactMap { observation -> OCRTextBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let bounds = observation.boundingBox
                    return OCRTextBlock(
                        text: candidate.string,
                        confidence: Double(candidate.confidence),
                        normalizedBounds: TraceRect(
                            x: Self.clamp(bounds.minX),
                            y: Self.clamp(1 - bounds.maxY),
                            width: Self.clamp(bounds.width),
                            height: Self.clamp(bounds.height)
                        )
                    )
                }
                .sorted(by: Self.readingOrder)

            return OCRDocument(
                engine: "apple-vision",
                recognitionLanguages: languages,
                blocks: blocks
            )
        }.value
    }

    private static func clamp(_ value: CGFloat) -> Double {
        Double(min(max(value, 0), 1))
    }

    private static func readingOrder(_ lhs: OCRTextBlock, _ rhs: OCRTextBlock) -> Bool {
        let rowTolerance = max(lhs.normalizedBounds.height, rhs.normalizedBounds.height) * 0.5
        if abs(lhs.normalizedBounds.y - rhs.normalizedBounds.y) > rowTolerance {
            return lhs.normalizedBounds.y < rhs.normalizedBounds.y
        }
        return lhs.normalizedBounds.x < rhs.normalizedBounds.x
    }
}
