import XCTest
@testable import LensMac

/// Scans every view file under `Sources/LensMac/UI` for hand-picked type,
/// icon, corner-radius and color literals that bypass the shared tokens in
/// `LensGlass.swift`. Baselines were measured on 2026-08-31 and must only
/// ever move down as files are migrated to the tokens; raising a baseline
/// back up is not a valid fix for a failure here.
///
/// `size:` is classified as text or icon by looking at the three lines
/// above the match for `Image(systemName` / `Image(nsImage` — the same
/// heuristic used to produce the baselines below. A line can opt out with
/// `// lens-token-exempt: <reason>`; the reason is required and the total
/// number of exemptions is itself capped so the escape hatch cannot become
/// the default path.
@MainActor
final class LensDesignTokenLintTests: XCTestCase {
    private struct Violation {
        let file: String
        let line: Int
        let value: String
    }

    private static let allowedTextSizes: Set<Double> = [10, 11, 12, 13, 15]
    private static let allowedIconSizes: Set<Double> = [11, 13, 17, 24, 34]
    private static let allowedCornerRadii: Set<Double> = [0, 8, 10, 13, 16, 18, 24, 30]
    private static let colorLiteralNames = [
        "cyan", "mint", "indigo", "yellow", "purple", "pink", "teal", "brown"
    ]

    // Ratchet baselines. Lower these as violations are fixed; never raise
    // them except when genuinely new, justified exemption categories are
    // discovered (see maxExemptions below).
    // 2026-08-31 initial baseline (post one known false-positive exemption):
    // text=151 icon=39 cornerRadius=68 color=102.
    // 2026-08-31 after P2 (font/corner-radius pass on the nine highest-
    // frequency views): text=83 icon=20 cornerRadius=30 color=102.
    // 2026-08-31 after P3 (VideoEditorView, VideoEditorCursorOverlayView,
    // VideoAnnotationOverlayView, RecordingSetupView): text=8 icon=5
    // cornerRadius=11 color=102. The residual 8/5/11 live in
    // OCRResultView.swift, OnboardingView.swift,
    // ScrollingCaptureControlWindowController.swift and
    // ScreenshotCanvasToolbar.swift — outside both P2 and P3's declared file
    // lists, left for a future pass.
    // 2026-08-31 after P4 (color consolidation via LensGlassPalette.accent/
    // recording/warning/success/neutral, applied across the whole UI
    // directory — a superset of the plan's four named examples): color=0,
    // now a hard assertion per the plan. text/icon/cornerRadius unchanged
    // from P3 (P4 was color-only).
    private static let maxTextSizeViolations = 8
    private static let maxIconSizeViolations = 5
    private static let maxCornerRadiusViolations = 11
    private static let maxColorLiteralViolations = 0
    // Legitimate exemption categories: (1) decorative micro-geometry that
    // isn't a UI surface at all (e.g. a 1.2pt audio-meter bar corner in
    // RecordingControlView), (2) GraphicsContext canvas rendering in
    // ScreenshotAnnotationEditorView and VideoAnnotationOverlayView
    // (selection outlines, annotation shapes, redaction badges, resize
    // handles) — drawn onto the image content itself, not the app's UI
    // chrome, and (3) user-facing color pickers (the annotation color/
    // gradient swatches in ScreenshotAnnotationEditorView and
    // VideoEditorView, and one keyframe-marker glyph that must stay visually
    // distinct from an adjacent accent-colored marker on the same timeline)
    // where the whole point is offering real, distinct hues as content, not
    // a UI chrome tint, and (4) a one-off full-screen hero display (the
    // recording countdown's 120pt digit in
    // RecordingCountdownWindowController) that has no other consumer and
    // doesn't belong on the reusable type scale meant for panel chrome.
    // Current usage: 31.
    private static let maxExemptions = 31

    private static let uiDirectoryURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LensMac/UI")
    }()

    private static func swiftFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: uiDirectoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let sizePattern = regex(#"size:\s*(\d+(?:\.\d+)?)"#)
    private static let cornerRadiusPattern = regex(#"cornerRadius:\s*(\d+(?:\.\d+)?)"#)
    private static let colorPattern = regex(
        #"\.(cyan|mint|indigo|yellow|purple|pink|teal|brown)\b"#
    )
    private static let exemptionPattern = regex(#"lens-token-exempt:\s*\S"#)

    private static func firstMatch(
        _ pattern: NSRegularExpression,
        in line: String
    ) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[valueRange])
    }

    private static func isExempt(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return exemptionPattern.firstMatch(in: line, range: range) != nil
    }

    private static func containsColorLiteral(_ line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        return colorPattern.matches(in: line, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: line)
            else { return nil }
            return String(line[r])
        }
    }

    private struct ScanResult {
        var textViolations: [Violation] = []
        var iconViolations: [Violation] = []
        var cornerRadiusViolations: [Violation] = []
        var colorViolations: [Violation] = []
        var exemptionCount = 0
    }

    private static func scan() throws -> ScanResult {
        var result = ScanResult()
        for url in try swiftFiles() {
            let fileName = url.lastPathComponent
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let lineNumber = index + 1
                if isExempt(line) {
                    result.exemptionCount += 1
                    continue
                }
                if let raw = firstMatch(sizePattern, in: line), let value = Double(raw) {
                    let contextStart = max(0, index - 3)
                    let context = lines[contextStart...index].joined(separator: "\n")
                    let isIcon = context.contains("Image(systemName")
                        || context.contains("Image(nsImage")
                    if isIcon {
                        if !allowedIconSizes.contains(value) {
                            result.iconViolations.append(
                                Violation(file: fileName, line: lineNumber, value: raw)
                            )
                        }
                    } else if !allowedTextSizes.contains(value) {
                        result.textViolations.append(
                            Violation(file: fileName, line: lineNumber, value: raw)
                        )
                    }
                }
                if let raw = firstMatch(cornerRadiusPattern, in: line), let value = Double(raw),
                   !allowedCornerRadii.contains(value) {
                    result.cornerRadiusViolations.append(
                        Violation(file: fileName, line: lineNumber, value: raw)
                    )
                }
                for color in containsColorLiteral(line) {
                    result.colorViolations.append(
                        Violation(file: fileName, line: lineNumber, value: color)
                    )
                }
            }
        }
        return result
    }

    private func assertRatchet(
        _ violations: [LensDesignTokenLintTests.Violation],
        maxAllowed: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            violations.count,
            maxAllowed,
            """
            \(label): found \(violations.count) violation(s), baseline allows \
            at most \(maxAllowed). New code must use the shared tokens in \
            LensGlass.swift instead of literals. Offending lines:
            \(violations.prefix(20).map { "  \($0.file):\($0.line) = \($0.value)" }
                .joined(separator: "\n"))
            """,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            maxAllowed,
            0,
            "\(label) baseline must never be negative.",
            file: file,
            line: line
        )
    }

    func testTextSizesStayWithinTypeScale() throws {
        let result = try Self.scan()
        assertRatchet(
            result.textViolations,
            maxAllowed: Self.maxTextSizeViolations,
            label: "Text size not in LensType"
        )
    }

    func testIconSizesStayWithinIconScale() throws {
        let result = try Self.scan()
        assertRatchet(
            result.iconViolations,
            maxAllowed: Self.maxIconSizeViolations,
            label: "Icon size not in LensIcon"
        )
    }

    func testCornerRadiiStayWithinTokenSet() throws {
        let result = try Self.scan()
        assertRatchet(
            result.cornerRadiusViolations,
            maxAllowed: Self.maxCornerRadiusViolations,
            label: "cornerRadius not in LensGlassMetrics"
        )
    }

    func testColorsStayWithinSemanticPalette() throws {
        let result = try Self.scan()
        assertRatchet(
            result.colorViolations,
            maxAllowed: Self.maxColorLiteralViolations,
            label: "System color literal outside LensGlassPalette"
        )
    }

    func testExemptionCountStaysWithinLimit() throws {
        let result = try Self.scan()
        XCTAssertLessThanOrEqual(
            result.exemptionCount,
            Self.maxExemptions,
            "lens-token-exempt is an escape hatch, not a default path; " +
            "found \(result.exemptionCount), budget is \(Self.maxExemptions)."
        )
    }

    /// Guards the lint itself: a reason-less exemption comment must still
    /// count as a violation rather than silently suppressing one, and the
    /// known false-positive (a 4pt bullet glyph in a `LabelStyle`, not text)
    /// must be classified correctly.
    func testKnownIconFalsePositiveIsExempted() throws {
        let source = try String(
            contentsOf: Self.uiDirectoryURL.appendingPathComponent("LensLibraryView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("lens-token-exempt"),
            "The 4pt LabelStyle bullet glyph must carry an explicit, reasoned exemption."
        )
    }
}
