import Foundation
import XCTest
@testable import ScreenTraceMac

@MainActor
final class AppModelPreferencesTests: XCTestCase {
    func testRecordingMediaPreferencesPersistWithSafeDefaults() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppModel(defaults: defaults)
        XCTAssertTrue(initial.capturesSystemAudio)
        XCTAssertFalse(initial.capturesMicrophone)
        XCTAssertFalse(initial.capturesCamera)
        XCTAssertEqual(initial.recordingFrameRate, .fps60)
        XCTAssertTrue(initial.automaticallyTranscribesRecordings)
        XCTAssertEqual(initial.transcriptionLanguage, .automatic)

        initial.capturesSystemAudio = false
        initial.capturesMicrophone = true
        initial.capturesCamera = true
        initial.recordingFrameRate = .fps30
        initial.automaticallyTranscribesRecordings = false
        initial.transcriptionLanguage = .simplifiedChinese
        let restored = AppModel(defaults: defaults)

        XCTAssertFalse(restored.capturesSystemAudio)
        XCTAssertTrue(restored.capturesMicrophone)
        XCTAssertTrue(restored.capturesCamera)
        XCTAssertEqual(restored.recordingFrameRate, .fps30)
        XCTAssertFalse(restored.automaticallyTranscribesRecordings)
        XCTAssertEqual(restored.transcriptionLanguage, .simplifiedChinese)
    }

    func testUnsupportedStoredFrameRateFallsBackToSixtyFPS() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(120, forKey: "recording.framesPerSecond")

        XCTAssertEqual(AppModel(defaults: defaults).recordingFrameRate, .fps60)
    }

    func testUnsupportedStoredTranscriptionLanguageFallsBackToAutomatic() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("elvish", forKey: "analysis.transcriptionLanguage")

        XCTAssertEqual(AppModel(defaults: defaults).transcriptionLanguage, .automatic)
    }

    func testTranscriptionLanguagesMapToStableSpeechLocales() {
        XCTAssertEqual(TranscriptionLanguage.simplifiedChinese.localeIdentifier, "zh-CN")
        XCTAssertEqual(TranscriptionLanguage.traditionalChinese.localeIdentifier, "zh-TW")
        XCTAssertEqual(TranscriptionLanguage.english.localeIdentifier, "en-US")
        XCTAssertEqual(TranscriptionLanguage.japanese.localeIdentifier, "ja-JP")
        XCTAssertEqual(TranscriptionLanguage.korean.localeIdentifier, "ko-KR")
        XCTAssertFalse(TranscriptionLanguage.automatic.localeIdentifier.isEmpty)
    }
}
