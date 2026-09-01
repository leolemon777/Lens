import Foundation
import LensCore
import XCTest
@testable import LensMac

final class NarrationSpeechAndCodeCardTests: XCTestCase {
    // MARK: - 配音草稿脚本

    func testScriptDropsFillerParticlesAndJoinsSegments() {
        let transcript = TranscriptDocument(
            engine: "test",
            localeIdentifier: "zh-CN",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [
                TranscriptSegment(startSeconds: 0, endSeconds: 2, text: "嗯 先打开设置", confidence: 0.9),
                TranscriptSegment(startSeconds: 2, endSeconds: 4, text: "然后点击保存 um", confidence: 0.9)
            ]
        )
        let script = NarrationSpeechSynthesizer.script(from: transcript)
        XCTAssertEqual(script, "先打开设置 然后点击保存")
    }

    func testScriptRespectsMaximumLength() {
        let transcript = TranscriptDocument(
            engine: "test",
            localeIdentifier: "en-US",
            isOnDevice: true,
            sourceRole: .microphone,
            segments: [
                TranscriptSegment(
                    startSeconds: 0,
                    endSeconds: 10,
                    text: String(repeating: "hello ", count: 400),
                    confidence: 0.9
                )
            ]
        )
        let script = NarrationSpeechSynthesizer.script(from: transcript, maximumCharacters: 100)
        XCTAssertLessThanOrEqual(script.count, 100)
    }

    // MARK: - 代码卡片

    func testCodeDetectionRequiresLinesAndASignal() {
        XCTAssertTrue(CodeCardRenderer.isLikelyCode(
            "func greet() {\n    print(1)\n}\n"
        ))
        XCTAssertTrue(CodeCardRenderer.isLikelyCode(
            "import Foundation\nlet a = 1\nlet b = 2"
        ))
        XCTAssertFalse(CodeCardRenderer.isLikelyCode(
            "这是一段普通文字\n没有代码特征\n真的没有"
        ))
        XCTAssertFalse(CodeCardRenderer.isLikelyCode("let a = 1"))
        XCTAssertFalse(CodeCardRenderer.isLikelyCode(""))
    }

    func testCodeCardRenderProducesBitmapWithContent() throws {
        let image = try XCTUnwrap(CodeCardRenderer.render(text: "func a() {\n  return 1\n}\n"))
        XCTAssertGreaterThan(image.width, 100)
        XCTAssertGreaterThan(image.height, 60)
        XCTAssertNil(CodeCardRenderer.render(text: ""))
    }
}
