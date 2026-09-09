import Foundation
import XCTest
@testable import LensCore
@testable import LensMac

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
            fullText: "Hello Lens",
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
                    text: "Lens",
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
        XCTAssertEqual(document.fullText, "Hello Lens")
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

    func testSpeechFrameworkFailureCodesBecomeActionableLocalErrors() {
        let noSpeech = LocalSpeechTranscriptionService.classifyRecognitionError(
            NSError(domain: "kAFAssistantErrorDomain", code: 1110),
            localeIdentifier: "zh-CN"
        )
        XCTAssertEqual(noSpeech as? LocalSpeechTranscriptionError, .noSpeechDetected)

        let dictationDisabled = LocalSpeechTranscriptionService.classifyRecognitionError(
            NSError(domain: "kLSRErrorDomain", code: 201),
            localeIdentifier: "zh-CN"
        )
        XCTAssertEqual(
            dictationDisabled as? LocalSpeechTranscriptionError,
            .authorizationDenied
        )

        let denied = LocalSpeechTranscriptionService.classifyRecognitionError(
            NSError(domain: "kAFAssistantErrorDomain", code: 1700),
            localeIdentifier: "zh-CN"
        )
        XCTAssertEqual(denied as? LocalSpeechTranscriptionError, .authorizationDenied)

        let unavailable = LocalSpeechTranscriptionService.classifyRecognitionError(
            NSError(domain: "kLSRErrorDomain", code: 300),
            localeIdentifier: "en-US"
        )
        XCTAssertEqual(
            unavailable as? LocalSpeechTranscriptionError,
            .recognizerUnavailable("en-US")
        )

        let failed = LocalSpeechTranscriptionService.classifyRecognitionError(
            NSError(domain: "kAFAssistantErrorDomain", code: 203),
            localeIdentifier: "zh-CN"
        )
        XCTAssertEqual(failed as? LocalSpeechTranscriptionError, .recognitionFailed)
        XCTAssertTrue(
            (failed as? LocalSpeechTranscriptionError)?.errorDescription?.contains("原始音轨") == true
        )
    }

    func testSpeechCancellationRemainsCancellationError() {
        let classified = LocalSpeechTranscriptionService.classifyRecognitionError(
            NSError(domain: "kLSRErrorDomain", code: 301),
            localeIdentifier: "zh-CN"
        )
        XCTAssertTrue(classified is CancellationError)
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
