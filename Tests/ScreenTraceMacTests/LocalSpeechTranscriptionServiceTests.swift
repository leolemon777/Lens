import Foundation
import XCTest
@testable import ScreenTraceCore
@testable import ScreenTraceMac

final class LocalSpeechTranscriptionServiceTests: XCTestCase {
    func testAuthorizationContinuationCanResumeFromBackgroundExecutor() async {
        let status = await withCheckedContinuation { continuation in
            let callback = LocalSpeechTranscriptionService.authorizationCallback(continuation)
            DispatchQueue.global().async {
                callback(.authorized)
            }
        }

        XCTAssertEqual(status, .authorized)
    }

    func testAppleSpeechSegmentsMapIntoPortableOnDeviceDocument() {
        let generatedAt = Date(timeIntervalSince1970: 500.9)
        let document = LocalSpeechTranscriptionService.makeDocument(
            fullText: "Hello 屏迹",
            segments: [
                LocalSpeechSegment(
                    startSeconds: 0.25,
                    durationSeconds: 0.4,
                    text: "Hello",
                    confidence: 0.92
                ),
                LocalSpeechSegment(
                    startSeconds: 0.8,
                    durationSeconds: 0.5,
                    text: "屏迹",
                    confidence: 0.88
                )
            ],
            localeIdentifier: "zh-CN",
            sourceRole: .microphone,
            generatedAt: generatedAt
        )

        XCTAssertEqual(document.engine, "apple-speech")
        XCTAssertTrue(document.isOnDevice)
        XCTAssertEqual(document.sourceRole, .microphone)
        XCTAssertEqual(document.fullText, "Hello 屏迹")
        XCTAssertEqual(document.generatedAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(document.segments[0].startSeconds, 0.25, accuracy: 0.001)
        XCTAssertEqual(document.segments[0].endSeconds, 0.65, accuracy: 0.001)
        XCTAssertEqual(document.segments[1].endSeconds, 1.3, accuracy: 0.001)
    }

    func testEmptyFinalRecognitionIsRejectedInsteadOfBeingMarkedComplete() throws {
        let document = LocalSpeechTranscriptionService.makeDocument(
            fullText: "   \n",
            segments: [],
            localeIdentifier: "zh-CN",
            sourceRole: .screenVideo
        )

        XCTAssertThrowsError(try LocalSpeechTranscriptionService.validatedDocument(document)) {
            XCTAssertEqual($0 as? LocalSpeechTranscriptionError, .noFinalResult)
        }
    }

    @MainActor
    func testMissingAudioIsRejectedBeforeRequestingSpeechPermission() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-speech-\(UUID().uuidString).caf")
        do {
            _ = try await LocalSpeechTranscriptionService().transcribe(
                audioURL: url,
                localeIdentifier: "en-US",
                sourceRole: .microphone
            )
            XCTFail("Expected missing source error")
        } catch let error as LocalSpeechTranscriptionError {
            XCTAssertEqual(error, .missingSource)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
