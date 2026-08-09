import Foundation
import XCTest
@testable import ScreenTraceCore

final class AutoEditPlanTests: XCTestCase {
    func testAudioPlanClampsUnsafeValuesAndRemainsBackwardCompatible() throws {
        let audio = AutoEditPlan.Audio(
            systemVolume: -1,
            microphoneVolume: 3,
            duckedSystemVolume: 2,
            narrationThresholdDecibels: -100,
            duckAttackSeconds: -1,
            duckReleaseSeconds: 4
        )

        XCTAssertEqual(audio.systemVolume, 0)
        XCTAssertEqual(audio.microphoneVolume, 2)
        XCTAssertEqual(audio.duckedSystemVolume, 1)
        XCTAssertEqual(audio.narrationThresholdDecibels, -80)
        XCTAssertEqual(audio.duckAttackSeconds, 0)
        XCTAssertEqual(audio.duckReleaseSeconds, 3)

        let encoded = try JSONEncoder().encode(AutoEditPlan())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "audio")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AutoEditPlan.self, from: legacyData)

        XCTAssertNil(decoded.audio)
    }

    func testCaptionPlanClampsValuesAndLegacyPlanDecodesWithoutCaptions() throws {
        let captions = AutoEditPlan.Captions(
            isEnabled: true,
            fontScale: 9,
            maxCharactersPerCue: 2,
            verticalMargin: -1
        )
        XCTAssertEqual(captions.fontScale, 1.6)
        XCTAssertEqual(captions.maxCharactersPerCue, 8)
        XCTAssertEqual(captions.verticalMargin, 0)

        let encoded = try JSONEncoder().encode(AutoEditPlan())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "captions")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AutoEditPlan.self, from: legacyData)

        XCTAssertNil(decoded.captions)
    }
}
