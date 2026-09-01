import CoreGraphics
import CoreText
import Foundation
import LensCore

/// Renders OCR'd text as a developer-style "code card": dark canvas, mono
/// type, line numbers. Pure CoreGraphics so it works anywhere, headless.
struct CodeCardRenderer {
    static let minimumCodeLines = 3

    /// Cheap heuristic: enough lines plus at least one strong code signal.
    static func isLikelyCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmpty = lines.filter { !$0.isEmpty }
        guard nonEmpty.count >= minimumCodeLines else { return false }
        let signals: [String] = ["{", "}", ";", "=>", "func ", "import ", "def ", "let ", "var ", "return", "class ", "#include", "public ", "if (", "for ("]
        return nonEmpty.contains { line in
            signals.contains { line.contains($0) }
        }
    }

    static func render(text: String, fontSize: CGFloat = 26) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rawLines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let lineNumberFont = CTFontCreateWithName("Menlo" as CFString, fontSize * 0.82, nil)
        let lineHeight = fontSize * 1.5
        let horizontalPadding = fontSize * 1.6
        let verticalPadding = fontSize * 1.4
        let gutter = fontSize * 2.6

        let measured = rawLines.prefix(80).map { line -> CGFloat in
            let attributed = NSAttributedString(string: String(line), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let longestLine = measured.max() ?? fontSize * 10
        let width = Int((horizontalPadding * 2 + gutter + longestLine).rounded(.up))
        let height = Int((verticalPadding * 2 + lineHeight * CGFloat(min(rawLines.count, 80))).rounded(.up))
        guard width > 0, width < 8_000, height > 0 else { return nil }

        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setFillColor(CGColor(srgbRed: 0.086, green: 0.094, blue: 0.114, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        // Subtle window chrome bar.
        context.setFillColor(CGColor(srgbRed: 0.118, green: 0.128, blue: 0.152, alpha: 1))
        context.fill(CGRect(
            x: 0,
            y: CGFloat(height) - fontSize * 1.6,
            width: CGFloat(width),
            height: fontSize * 1.6
        ))

        let textColor = CGColor(srgbRed: 0.90, green: 0.92, blue: 0.94, alpha: 1)
        let gutterColor = CGColor(srgbRed: 0.45, green: 0.48, blue: 0.55, alpha: 1)
        let visibleLines = rawLines.prefix(80)
        for (index, rawLine) in visibleLines.enumerated() {
            let row = CGFloat(visibleLines.count - 1 - index)
            let baseline = verticalPadding + row * lineHeight + fontSize * 0.32
            let number = NSAttributedString(string: "\(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): lineNumberFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): gutterColor
            ])
            context.textPosition = CGPoint(x: horizontalPadding, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(number), context)

            let line = NSAttributedString(string: String(rawLine), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
            ])
            context.textPosition = CGPoint(x: horizontalPadding + gutter, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        return context.makeImage()
    }
}
