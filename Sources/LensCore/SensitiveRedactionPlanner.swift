import Foundation

/// Turns sensitive-text findings in a screenshot's OCR into ready-to-review
/// pixelation annotations. Suggestion rects stay inside the OCR block's
/// normalized bounds, so they line up with the annotation editor's geometry
/// without any pixel conversion.
public struct SensitiveRedactionPlanner: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Extra width around a hit, as a fraction of the hit's own width.
        public var horizontalPaddingRatio: Double
        /// Extra height above/below the text line, as a fraction of block height.
        public var verticalExpansionRatio: Double
        public var pixelateIntensity: Double
        public var maximumSuggestions: Int

        public init(
            horizontalPaddingRatio: Double = 0.35,
            verticalExpansionRatio: Double = 0.3,
            pixelateIntensity: Double = 0.05,
            maximumSuggestions: Int = 40
        ) {
            self.horizontalPaddingRatio = min(max(horizontalPaddingRatio, 0), 2)
            self.verticalExpansionRatio = min(max(verticalExpansionRatio, 0), 2)
            self.pixelateIntensity = min(max(pixelateIntensity, 0.004), 0.06)
            self.maximumSuggestions = max(maximumSuggestions, 1)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func suggestions(ocr: OCRDocument) -> [ScreenshotAnnotation] {
        var result: [ScreenshotAnnotation] = []
        for block in ocr.blocks {
            guard result.count < configuration.maximumSuggestions else { break }
            let matches = LocalLensOrganizer.sensitiveMatches(in: block.text)
            guard !matches.isEmpty else { continue }
            let total = max(Double(block.text.utf16.count), 1)
            let bounds = block.normalizedBounds

            // Merge hits whose padded spans overlap so one dense line does not
            // produce a stack of near-identical rects.
            let spans = matches
                .map { match -> (start: Double, end: Double) in
                    let start = Double(match.range.location) / total
                    let end = Double(match.range.location + match.range.length) / total
                    let padding = max((end - start) * configuration.horizontalPaddingRatio, 0.004)
                    return (max(start - padding, 0), min(end + padding, 1))
                }
                .sorted { $0.start < $1.start }
            var merged: [(start: Double, end: Double)] = []
            for span in spans {
                if let last = merged.last, span.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, span.end)
                } else {
                    merged.append(span)
                }
            }

            let verticalPadding = bounds.height * configuration.verticalExpansionRatio
            for span in merged {
                let rect = LensRect(
                    x: bounds.x + span.start * bounds.width,
                    y: max(bounds.y - verticalPadding, 0),
                    width: (span.end - span.start) * bounds.width,
                    height: min(bounds.height + verticalPadding * 2, 1)
                )
                guard rect.width > 0.001, rect.height > 0.001 else { continue }
                result.append(ScreenshotAnnotation(
                    kind: .pixelate,
                    bounds: rect,
                    style: ScreenshotAnnotationStyle(
                        intensity: configuration.pixelateIntensity
                    )
                ))
            }
        }
        return result
    }
}
