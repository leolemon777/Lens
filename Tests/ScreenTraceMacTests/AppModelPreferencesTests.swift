import Foundation
import XCTest
@testable import ScreenTraceMac

@MainActor
final class AppModelPreferencesTests: XCTestCase {
    func testRecordingAudioPreferencesPersistWithSafeDefaults() throws {
        let suiteName = "ScreenTraceAppModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = AppModel(defaults: defaults)
        XCTAssertTrue(initial.capturesSystemAudio)
        XCTAssertFalse(initial.capturesMicrophone)

        initial.capturesSystemAudio = false
        initial.capturesMicrophone = true
        let restored = AppModel(defaults: defaults)

        XCTAssertFalse(restored.capturesSystemAudio)
        XCTAssertTrue(restored.capturesMicrophone)
    }
}
