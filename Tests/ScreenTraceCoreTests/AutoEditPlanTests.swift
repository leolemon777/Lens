import Foundation
import XCTest
@testable import ScreenTraceCore

final class AutoEditPlanTests: XCTestCase {
    func testAudioPlanClampsUnsafeValuesAndRemainsBackwardCompatible() throws {
        let audio = AutoEditPlan.Audio(
            systemVolume: -1,
            microphoneVolume: 3,
            noiseReductionAmount: 8,
            targetLoudnessLUFS: -40,
            duckedSystemVolume: 2,
            narrationThresholdDecibels: -100,
            duckAttackSeconds: -1,
            duckReleaseSeconds: 4
        )

        XCTAssertEqual(audio.systemVolume, 0)
        XCTAssertEqual(audio.microphoneVolume, 2)
        XCTAssertEqual(audio.noiseReductionAmount, 1)
        XCTAssertEqual(audio.targetLoudnessLUFS, -24)
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

    func testLegacyAudioPlanDoesNotSilentlyEnableNewVoiceProcessing() throws {
        let data = Data(#"""
        {
          "isEnabled": true,
          "systemVolume": 0.8,
          "microphoneVolume": 1.1,
          "ducksSystemUnderNarration": true,
          "duckedSystemVolume": 0.3,
          "narrationThresholdDecibels": -40,
          "duckAttackSeconds": 0.1,
          "duckReleaseSeconds": 0.4
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(AutoEditPlan.Audio.self, from: data)

        XCTAssertFalse(decoded.reducesMicrophoneNoise)
        XCTAssertFalse(decoded.normalizesLoudness)
        XCTAssertEqual(decoded.noiseReductionAmount, 0.55)
        XCTAssertEqual(decoded.targetLoudnessLUFS, -16)
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

    func testExportPresetRoundTripsAndLegacyPlanPreservesSourceQuality() throws {
        let plan = AutoEditPlan(export: .init(preset: .compact))
        let encoded = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(AutoEditPlan.self, from: encoded)

        XCTAssertEqual(decoded.export?.preset, .compact)
        XCTAssertEqual(decoded.schemaVersion, "0.8")

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "export")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(AutoEditPlan.self, from: legacyData)

        XCTAssertNil(legacy.export)
    }
}
