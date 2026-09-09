import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

@MainActor
final class RecordingContentTaskPresentationTests: XCTestCase {
    func testTranscriptionCompletionUsesSegmentCountAndReloads() {
        var reloadCount = 0
        var toast: (String, String, String)?
        var diagnostic: (String, DiagnosticLevel, [String: String])?
        let presentation = makePresentation(
            reload: { reloadCount += 1 },
            toast: { toast = ($0, $1, $2) },
            diagnostic: { diagnostic = ($0, $1, $2) }
        )
        let document = TranscriptDocument(
            engine: "test",
            localeIdentifier: "zh-Hans",
            isOnDevice: true,
            sourceRole: .screenVideo,
            segments: [TranscriptSegment(
                startSeconds: 0,
                endSeconds: 1,
                text: "演示",
                confidence: 1
            )]
        )

        presentation.transcriptionCompleted(document)

        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(toast?.0, "本机转写已完成")
        XCTAssertTrue(toast?.1.contains("1 个时间片段") == true)
        XCTAssertEqual(diagnostic?.0, "transcription.completed")
        XCTAssertEqual(diagnostic?.2["count"], "1")
    }

    func testOrganizationCompletionSummarizesVisibleDetailsOnlyWhenAnnounced() {
        var reloadCount = 0
        var toastCount = 0
        let presentation = makePresentation(
            reload: { reloadCount += 1 },
            toast: { _, _, _ in toastCount += 1 }
        )
        let insights = LensInsightsDocument(
            engine: "test",
            suggestedTitle: "标题",
            summary: "摘要",
            tags: ["演示", "本地"],
            chapters: [LensChapter(
                index: 0,
                startSeconds: 0,
                endSeconds: 1,
                title: "开始",
                summary: "摘要"
            )],
            sensitiveFindings: [LensSensitiveFinding(
                kind: .emailAddress,
                source: .ocr,
                redactedPreview: "a***@example.com"
            )]
        )

        presentation.organizationCompleted(insights, announcesResult: false)
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(toastCount, 0)

        presentation.organizationCompleted(insights, announcesResult: true)
        XCTAssertEqual(reloadCount, 2)
        XCTAssertEqual(toastCount, 1)
    }

    func testOrganizationAlreadyRunningUsesTheSameUserFacingCopy() {
        var toast: (String, String, String)?
        let presentation = makePresentation(
            toast: { toast = ($0, $1, $2) }
        )

        presentation.organizationAlreadyRunning()

        XCTAssertEqual(toast?.0, "这条 Lens 正在整理")
        XCTAssertEqual(toast?.2, "sparkles")
    }

    func testFailuresKeepSafeMetadataAndUserFacingErrorDetailSeparate() {
        var failure: (String, [String: String])?
        var toastDetail = ""
        let presentation = RecordingContentTaskPresentation(
            reloadLibrary: {},
            showToast: { _, detail, _ in toastDetail = detail },
            recordDiagnostic: { _, _, _ in },
            recordFailure: { code, metadata in failure = (code, metadata) }
        )

        presentation.transcriptionFailed(
            ["errorDomain": "LensError", "errorCode": "7"],
            detail: "本机语言包不可用"
        )

        XCTAssertEqual(failure?.0, "transcription.failed")
        XCTAssertEqual(failure?.1["errorDomain"], "LensError")
        XCTAssertTrue(toastDetail.contains("本机语言包不可用"))
        XCTAssertFalse(failure?.1.values.contains("本机语言包不可用") == true)
    }

    private func makePresentation(
        reload: @escaping @MainActor @Sendable () -> Void = {},
        toast: @escaping @MainActor @Sendable (String, String, String) -> Void = { _, _, _ in },
        diagnostic: @escaping @MainActor @Sendable (String, DiagnosticLevel, [String: String]) -> Void = { _, _, _ in }
    ) -> RecordingContentTaskPresentation {
        RecordingContentTaskPresentation(
            reloadLibrary: reload,
            showToast: toast,
            recordDiagnostic: diagnostic,
            recordFailure: { _, _ in }
        )
    }
}
