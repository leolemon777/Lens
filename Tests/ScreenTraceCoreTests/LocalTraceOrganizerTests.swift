import Foundation
import XCTest
@testable import ScreenTraceCore

final class LocalTraceOrganizerTests: XCTestCase {
    func testScreenshotOrganizationBuildsSafeTitleSummaryTagsAndFindings() throws {
        let manifest = TraceManifest(
            kind: .screenshot,
            createdAt: Date(timeIntervalSince1970: 10),
            title: "截图",
            dimensions: TraceDimensions(width: 1_280, height: 720),
            captureSource: TraceCaptureMetadata(
                mode: .window,
                windowID: 7,
                globalBounds: TraceRect(x: 0, y: 0, width: 1_280, height: 720),
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
                    text: "ScreenTrace launch roadmap. Contact alice@example.com. api_key: sk-abcdefghijklmnop.",
                    confidence: 1,
                    normalizedBounds: TraceRect(x: 0, y: 0, width: 1, height: 1)
                )
            ]
        )

        let insights = LocalTraceOrganizer.organize(
            manifest: manifest,
            ocr: ocr,
            generatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(insights.engine, LocalTraceOrganizer.engineIdentifier)
        XCTAssertTrue(insights.suggestedTitle.hasPrefix("Safari · ScreenTrace launch"))
        XCTAssertTrue(insights.tags.contains("Safari"))
        XCTAssertTrue(insights.tags.contains("产品"))
        XCTAssertTrue(insights.tags.contains("ScreenTrace"))
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
                segment(28, 31, "屏迹。"),
                segment(40, 44, "第二部分"),
                segment(96, 100, "自动整理。"),
                segment(104, 108, "联系"),
                segment(108, 111, "13800138000")
            ]
        )
        let manifest = TraceManifest(
            kind: .recording,
            title: "录屏",
            durationSeconds: 112,
            dimensions: TraceDimensions(width: 1_920, height: 1_080),
            assets: []
        )

        let insights = LocalTraceOrganizer.organize(
            manifest: manifest,
            transcript: transcript,
            generatedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(insights.summary.contains("今天介绍屏迹。"))
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
                    normalizedBounds: TraceRect(x: 0, y: 0, width: 1, height: 1)
                )
            ]
        )
        let insights = LocalTraceOrganizer.organize(
            manifest: TraceManifest(
                kind: .screenshot,
                title: "Payment",
                dimensions: TraceDimensions(width: 100, height: 100),
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
        let insights = LocalTraceOrganizer.organize(
            manifest: TraceManifest(
                kind: .recording,
                title: "Support",
                durationSeconds: 8,
                dimensions: TraceDimensions(width: 100, height: 100),
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

    func testSensitiveCaptureMetadataCannotLeakThroughTitleOrTags() throws {
        let accessKey = "AKIA1234567890ABCDEF"
        let email = "owner@example.com"
        let manifest = TraceManifest(
            kind: .screenshot,
            title: "Screenshot",
            dimensions: TraceDimensions(width: 100, height: 100),
            captureSource: TraceCaptureMetadata(
                mode: .window,
                windowID: 1,
                globalBounds: TraceRect(x: 0, y: 0, width: 100, height: 100),
                windowTitle: "Account \(email)",
                applicationName: accessKey
            ),
            assets: []
        )

        let insights = LocalTraceOrganizer.organize(
            manifest: manifest,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let encoded = String(decoding: try JSONEncoder().encode(insights), as: UTF8.self)

        XCTAssertFalse(encoded.contains(accessKey))
        XCTAssertFalse(encoded.contains(email))
        XCTAssertEqual(
            Set(insights.sensitiveFindings.map(\.kind)),
            Set([.credential, .emailAddress])
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
