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

        initial.capturesSystemAudio = false
        initial.capturesMicrophone = true
        initial.capturesCamera = true
        initial.recordingFrameRate = .fps30
        initial.automaticallyTranscribesRecordings = false
        let restored = AppModel(defaults: defaults)

        XCTAssertFalse(restored.capturesSystemAudio)
        XCTAssertTrue(restored.capturesMicrophone)
        XCTAssertTrue(restored.capturesCamera)
        XCTAssertEqual(restored.recordingFrameRate, .fps30)
        XCTAssertFalse(restored.automaticallyTranscribesRecordings)
    }

    func testUnsupportedStoredFrameRateFallsBackToSixtyFPS() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(120, forKey: "recording.framesPerSecond")

        XCTAssertEqual(AppModel(defaults: defaults).recordingFrameRate, .fps60)
    }
}
