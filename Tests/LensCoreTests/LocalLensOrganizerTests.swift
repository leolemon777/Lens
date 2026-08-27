import Foundation
import XCTest
@testable import LensCore

final class LocalLensOrganizerTests: XCTestCase {
    func testScreenshotOrganizationBuildsSafeTitleSummaryTagsAndFindings() throws {
        let manifest = LensManifest(
            kind: .screenshot,
            createdAt: Date(timeIntervalSince1970: 10),
            title: "截图",
            dimensions: LensDimensions(width: 1_280, height: 720),
            captureSource: LensCaptureMetadata(
                mode: .window,
                windowID: 7,
                globalBounds: LensRect(x: 0, y: 0, width: 1_280, height: 720),
                windowTitle: "Launch roadmap",
                applicationName: "Safari"
            ),
            assets: []
        )
        let ocr = OCRDocument(
            engine: "test",
            recognitionLanguages: ["en-US"],
            blocks: [
                OCRTextBlock(
                    text: "Lens launch roadmap. Contact alice@example.com. api_key: sk-abcdefghijklmnop.",
                    confidence: 1,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 1)
                )
            ]
        )

        let insights = LocalLensOrganizer.organize(
            manifest: manifest,
            ocr: ocr,
            generatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(insights.engine, LocalLensOrganizer.engineIdentifier)
        XCTAssertTrue(insights.suggestedTitle.hasPrefix("Safari · Lens launch"))
        XCTAssertTrue(insights.tags.contains("Safari"))
        XCTAssertTrue(insights.tags.contains("产品"))
        XCTAssertTrue(insights.tags.contains("Lens"))
        XCTAssertEqual(
            Set(insights.sensitiveFindings.map(\.kind)),
            Set([.emailAddress, .credential])
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(insights),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("alice@example.com"))
        XCTAssertFalse(encoded.contains("sk-abcdefghijklmnop"))
        XCTAssertTrue(encoded.contains("a•••@example.com"))
    }

    func testRecordingOrganizationCreatesChaptersAndChineseCompactSummary() {
        let transcript = TranscriptDocument(
            engine: "test",
            generatedAt: Date(timeIntervalSince1970: 0),
            localeIdentifier: "zh-Hans",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [
                segment(0, 4, "今天"),
                segment(4, 8, "介绍"),
                segment(28, 31, " Lens。"),
                segment(40, 44, "第二部分"),
                segment(96, 100, "自动整理。"),
                segment(104, 108, "联系"),
                segment(108, 111, "13800138000")
            ]
        )
        let manifest = LensManifest(
            kind: .recording,
            title: "录屏",
            durationSeconds: 112,
            dimensions: LensDimensions(width: 1_920, height: 1_080),
            assets: []
        )

        let insights = LocalLensOrganizer.organize(
            manifest: manifest,
            transcript: transcript,
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(insights.summary.contains("今天介绍 Lens。"))
        XCTAssertGreaterThanOrEqual(insights.chapters.count, 2)
        XCTAssertEqual(insights.chapters.map(\.index), Array(insights.chapters.indices))
        XCTAssertEqual(insights.chapters.first?.startSeconds, 0)
        XCTAssertTrue(insights.chapters.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(insights.sensitiveFindings.map(\.kind), [.phoneNumber])
        XCTAssertEqual(insights.sensitiveFindings.first?.startSeconds, 108)
        XCTAssertFalse(insights.summary.contains("13800138000"))
        XCTAssertFalse(insights.chapters.contains { $0.summary.contains("13800138000") })
    }

    func testPaymentCardUsesLuhnAndStoresOnlyMaskedSuffix() throws {
        let ocr = OCRDocument(
            engine: "test",
            recognitionLanguages: ["en-US"],
            blocks: [
                OCRTextBlock(
                    text: "Valid 4111 1111 1111 1111; invalid 4111 1111 1111 1112",
                    confidence: 1,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 1)
                )
            ]
        )
        let insights = LocalLensOrganizer.organize(
            manifest: LensManifest(
                kind: .screenshot,
                title: "Payment",
                dimensions: LensDimensions(width: 100, height: 100),
                assets: []
            ),
            ocr: ocr,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let cards = insights.sensitiveFindings.filter { $0.kind == .paymentCard }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].redactedPreview, "•••• 1111")
        let data = try JSONEncoder().encode(insights)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("4111 1111 1111 1111"))
    }

    func testSensitiveValueSplitAcrossTranscriptSegmentsIsLocatedAndRedacted() throws {
        let transcript = TranscriptDocument(
            engine: "test",
            localeIdentifier: "en-US",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [
                segment(4, 5, "Contact alice@"),
                segment(5, 7, "example.com for access")
            ]
        )
        let insights = LocalLensOrganizer.organize(
            manifest: LensManifest(
                kind: .recording,
                title: "Support",
                durationSeconds: 8,
                dimensions: LensDimensions(width: 100, height: 100),
                assets: []
            ),
            transcript: transcript,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let email = try XCTUnwrap(
            insights.sensitiveFindings.first { $0.kind == .emailAddress }
        )
        XCTAssertEqual(email.startSeconds, 4)
        XCTAssertEqual(email.endSeconds, 7)
        XCTAssertEqual(email.redactedPreview, "a•••@example.com")
        let encoded = String(decoding: try JSONEncoder().encode(insights), as: UTF8.self)
        XCTAssertFalse(encoded.contains("alice@example.com"))
        XCTAssertFalse(encoded.contains("alice@"))
    }

    /// An eighteen-digit order number is not an identity card. The payment-card
    /// rule already validates its checksum; the identity rule must do the same
    /// or it floods the panel with false positives users learn to ignore.
    func testEighteenDigitNumberWithoutAValidChecksumIsNotReported() {
        let ocr = OCRDocument(
            engine: "test",
            recognitionLanguages: ["zh-Hans"],
            blocks: [OCRTextBlock(
                text: "订单号 202608160000000123 已创建",
                confidence: 0.9,
                normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 1)
            )]
        )
        let manifest = LensManifest(
            kind: .screenshot,
            title: "订单",
            dimensions: LensDimensions(width: 1_920, height: 1_080),
            assets: []
        )

        let insights = LocalLensOrganizer.organize(manifest: manifest, ocr: ocr)

        XCTAssertFalse(
            insights.sensitiveFindings.contains { $0.kind == .governmentIdentifier },
            "无效校验位的 18 位数字被误报成了身份证号"
        )
    }

    /// A build number or a timestamp run is not a phone number.
    func testDigitRunThatIsNotAPhoneNumberIsNotReported() {
        let ocr = OCRDocument(
            engine: "test",
            recognitionLanguages: ["zh-Hans"],
            blocks: [OCRTextBlock(
                text: "构建 202608160931 完成",
                confidence: 0.9,
                normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 1)
            )]
        )
        let manifest = LensManifest(
            kind: .screenshot,
            title: "构建",
            dimensions: LensDimensions(width: 1_920, height: 1_080),
            assets: []
        )

        let insights = LocalLensOrganizer.organize(manifest: manifest, ocr: ocr)

        XCTAssertFalse(
            insights.sensitiveFindings.contains { $0.kind == .phoneNumber },
            "构建号被误报成了手机号"
        )
    }

    func testSensitiveCaptureMetadataCannotLeakThroughTitleOrTags() throws {
        let syntheticCredential = "api_key: synthetic-private-value"
        let email = "owner@example.com"
        let manifest = LensManifest(
            kind: .screenshot,
            title: "Screenshot",
            dimensions: LensDimensions(width: 100, height: 100),
            captureSource: LensCaptureMetadata(
                mode: .window,
                windowID: 1,
                globalBounds: LensRect(x: 0, y: 0, width: 100, height: 100),
                windowTitle: "Account \(email)",
                applicationName: syntheticCredential
            ),
            assets: []
        )

        let insights = LocalLensOrganizer.organize(
            manifest: manifest,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoded = String(decoding: try JSONEncoder().encode(insights), as: UTF8.self)

        XCTAssertFalse(encoded.contains(syntheticCredential))
        XCTAssertFalse(encoded.contains(email))
        XCTAssertEqual(
            Set(insights.sensitiveFindings.map(\.kind)),
            Set([.credential, .emailAddress])
        )
    }

    func testOrganizerDoesNotKeepDatedCaptureTitleWhenWindowIdentityExists() {
        let manifest = LensManifest(
            kind: .screenshot,
            title: "截图 2026年8月16日 04:12",
            dimensions: LensDimensions(width: 1_280, height: 720),
            screenshotCaptureSource: ScreenshotCaptureMetadata(
                mode: .window,
                windowIDs: [7],
                globalBounds: CGRect(x: 0, y: 0, width: 1_280, height: 720),
                windowTitle: "Launch roadmap",
                applicationName: "Safari"
            ),
            assets: []
        )

        let insights = LocalLensOrganizer.organize(
            manifest: manifest,
            generatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertTrue(
            insights.suggestedTitle.contains("Safari")
                || insights.suggestedTitle.contains("Launch"),
            "没有 OCR 时应当使用窗口身份，而不是截图日期"
        )
        XCTAssertFalse(insights.suggestedTitle.hasPrefix("截图 "))
        XCTAssertTrue(insights.tags.contains("Safari"))
    }

    func testOrganizerRejectsCalendarFragmentTitles() {
        let manifest = LensManifest(
            kind: .screenshot,
            title: "截图 2026年8月16日 05:01",
            dimensions: LensDimensions(width: 420, height: 352),
            screenshotCaptureSource: ScreenshotCaptureMetadata(
                mode: .window,
                windowIDs: [3],
                globalBounds: CGRect(x: 0, y: 0, width: 420, height: 352),
                windowTitle: "Calendar",
                applicationName: "Calendar"
            ),
            assets: []
        )
        let ocr = OCRDocument(
            engine: "test",
            recognitionLanguages: ["zh-Hans"],
            blocks: [
                OCRTextBlock(
                    text: "8月 七月初四 日一二三四五六",
                    confidence: 0.9,
                    normalizedBounds: LensRect(x: 0, y: 0, width: 1, height: 1)
                )
            ]
        )

        let insights = LocalLensOrganizer.organize(
            manifest: manifest,
            ocr: ocr,
            generatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertFalse(
            insights.suggestedTitle == "8月"
                || insights.suggestedTitle.hasPrefix("8月"),
            "日历表头不应成为标题"
        )
        XCTAssertTrue(
            insights.suggestedTitle.contains("Calendar"),
            "弱 OCR 时应回退到窗口身份"
        )
    }

    private func segment(
        _ start: Double,
        _ end: Double,
        _ text: String
    ) -> TranscriptSegment {
        TranscriptSegment(
            startSeconds: start,
            endSeconds: end,
            text: text,
            confidence: 1
        )
    }
}
