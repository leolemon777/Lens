import Foundation
import XCTest
@testable import ScreenTraceCore

final class AutoEditPlanTests: XCTestCase {
    func testLegacyCameraKeepsIntensityRenderingAndGainsSafeGenerationDefaults() throws {
        let data = Data(#"""
        {
          "mode": "event-driven",
          "zoomIntensity": 0.84,
          "followPointer": true,
          "keyframes": []
        }
        """#.utf8)

        let camera = try JSONDecoder().decode(AutoEditPlan.Camera.self, from: data)

        XCTAssertNil(camera.zoomScale)
        XCTAssertTrue(camera.clickToZoom)
        XCTAssertTrue(camera.followPointer)
        XCTAssertEqual(camera.generationStrength, .balanced)
        XCTAssertEqual(camera.motionBlurStrength, 0)
        XCTAssertEqual(camera.resolvedZoomScale, 2.16, accuracy: 0.000_1)
    }

    func testNewCameraRoundTripsAbsoluteZoomAndGenerationControls() throws {
        let camera = AutoEditPlan.Camera(
            mode: "event-driven",
            zoomIntensity: 0.42,
            followPointer: false,
            clickToZoom: true,
            zoomScale: 9,
            generationStrength: .active,
            motionBlurStrength: 8
        )

        let decoded = try JSONDecoder().decode(
            AutoEditPlan.Camera.self,
            from: JSONEncoder().encode(camera)
        )

        XCTAssertEqual(decoded.zoomScale, 3)
        XCTAssertEqual(decoded.resolvedZoomScale, 3)
        XCTAssertFalse(decoded.followPointer)
        XCTAssertTrue(decoded.clickToZoom)
        XCTAssertEqual(decoded.generationStrength, .active)
        XCTAssertEqual(decoded.motionBlurStrength, 1)
    }

    func testLegacyCursorAndInteractionGainNonDestructiveStyleDefaults() throws {
        let cursor = try JSONDecoder().decode(
            AutoEditPlan.Cursor.self,
            from: Data(#"{"smoothing":0.5,"scale":1.2,"hidesWhenIdle":true,"keyframes":[]}"#.utf8)
        )
        XCTAssertNil(cursor.smoothingWindowMilliseconds)
        XCTAssertEqual(cursor.resolvedSmoothingWindowMilliseconds, 40)
        XCTAssertEqual(cursor.appearance, .macOS)
        XCTAssertEqual(cursor.motionEffect, .none)
        XCTAssertTrue(cursor.shapeKeyframes.isEmpty)

        let interaction = try JSONDecoder().decode(
            AutoEditPlan.Interaction.self,
            from: Data(#"{"showsClickPulse":true,"clickPulses":[]}"#.utf8)
        )
        XCTAssertEqual(interaction.clickPulseScale, 1)
        XCTAssertNil(interaction.clickPulseDuration)
        XCTAssertEqual(interaction.clickPulseColorHex, "#00D9FF")
        XCTAssertEqual(interaction.clickEffect, .ripple)
        XCTAssertEqual(interaction.clickEffectStrength, 1)

        let newInteraction = AutoEditPlan.Interaction()
        XCTAssertEqual(newInteraction.clickPulseScale, 1.25)
        XCTAssertEqual(newInteraction.clickPulseDuration, 0.62)
        XCTAssertEqual(newInteraction.clickPulseColorHex, "#FF684D")
        XCTAssertEqual(newInteraction.clickEffect, .ripple)
        XCTAssertEqual(newInteraction.clickEffectStrength, 1)

        let customized = AutoEditPlan.Interaction(
            clickPulseScale: 9,
            clickPulseColorHex: "ff684d",
            clickPulseDuration: 9
        )
        XCTAssertEqual(customized.clickPulseScale, 3)
        XCTAssertEqual(customized.clickPulseColorHex, "#FF684D")
        XCTAssertEqual(customized.clickPulseDuration, 1.5)
    }

    func testCursorAppearanceMotionAndClickStylesRoundTripWithSafeClamping() throws {
        let plan = AutoEditPlan(
            cursor: AutoEditPlan.Cursor(
                appearance: .minimalDot,
                accentColorHex: "a3e635",
                motionEffect: .trail,
                motionEffectStrength: 9,
                smoothing: 0.72,
                scale: 1.4,
                hidesWhenIdle: false,
                shapeKeyframes: [
                    AutoEditPlan.CursorShapeKeyframe(time: 0.2, shape: .pointingHand)
                ]
            ),
            interaction: AutoEditPlan.Interaction(
                clickEffect: .spotlight,
                clickEffectStrength: -4
            )
        )

        let decoded = try JSONDecoder().decode(
            AutoEditPlan.self,
            from: JSONEncoder().encode(plan)
        )

        XCTAssertEqual(decoded.cursor.appearance, .minimalDot)
        XCTAssertEqual(decoded.cursor.accentColorHex, "#A3E635")
        XCTAssertEqual(decoded.cursor.motionEffect, .trail)
        XCTAssertEqual(decoded.cursor.motionEffectStrength, 1)
        XCTAssertEqual(decoded.cursor.shapeKeyframes.first?.shape, .pointingHand)
        XCTAssertEqual(decoded.interaction?.clickEffect, .spotlight)
        XCTAssertEqual(decoded.interaction?.clickEffectStrength, 0.1)
    }

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
        XCTAssertEqual(decoded.schemaVersion, "1.2")

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "export")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(AutoEditPlan.self, from: legacyData)

        XCTAssertNil(legacy.export)
    }
}
